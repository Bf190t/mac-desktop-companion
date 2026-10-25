"""Local JSON-lines worker. No listener, network inference, tools, or audio APIs."""
from pathlib import Path
import argparse, contextlib, ctypes, hashlib, json, os, queue, sys, threading, time

SOURCE=Path(__file__).resolve().parent
ROOT=Path(os.environ.get('COMPANION_CHAT_ROOT',str(SOURCE))).resolve()
os.environ.update(HF_HUB_OFFLINE='1',TRANSFORMERS_OFFLINE='1',HF_HUB_DISABLE_TELEMETRY='1',DO_NOT_TRACK='1',TOKENIZERS_PARALLELISM='false',HF_HOME=str(ROOT/'cache'),PYTHONDONTWRITEBYTECODE='1')
MAX_PROMPT=2048
MAX_OUTPUT=192
COMPANION_MAX_OUTPUT=128
IDLE_CHOICES=(120,1800)
COMPANION_BOUNDARY='固定事实：界面名小团（Mochi）；本地模型 Qwen3-1.7B（千问3）；只收到文字，语音由应用先转写。允许运用通用知识进行计算、解释、翻译和闲聊。只对用户私人经历、对话记忆和实时数据要求提供依据。没有实时时钟、联网、设备状态读取或电脑操作工具，不能猜实时数据或假称执行。跟随用户当前消息的语言，默认一至两句，总长最多120个字符。风格设定只调语气，不能改变这些事实。'
BASELINE='你是一个本地中文聊天助手。默认简洁回答1至3句，实用问题先给答案。仅依据当前可见对话；不知道就说明，不编造设备状态、实时消息、记忆或执行结果。'
lock=threading.Lock()
state_lock=threading.RLock()
protocol_out=sys.stdout
cancelled_ids=set()
cancel=threading.Event()
closing=threading.Event()
requests=queue.Queue(maxsize=16)
active_id=None
model=None
tokenizer=None
mx=None
process=None
residency=None
exit_reason=None

class IdlePolicy:
    """Monotonic inactivity deadline, disarmed while a reply is being produced."""
    def __init__(self,seconds=120,*,test_seconds=None,clock=time.monotonic):
        self._lock=threading.RLock();self.clock=clock
        self.seconds=self.validate(seconds)
        if test_seconds is not None:
            if not isinstance(test_seconds,(int,float)) or isinstance(test_seconds,bool) or not .1<=test_seconds<=30:
                raise ValueError('测试闲置时长必须为0.1至30秒。')
            self.seconds=float(test_seconds)
        self.last_activity=self.clock();self.last_kind='ready';self.busy=False
    @staticmethod
    def validate(seconds):
        if not isinstance(seconds,(int,float)) or isinstance(seconds,bool) or seconds not in IDLE_CHOICES:
            raise ValueError('驻留时长只支持120秒或1800秒。')
        return int(seconds)
    def touch(self,kind):
        with self._lock:self.last_activity=self.clock();self.last_kind=kind
    def begin_reply(self):
        with self._lock:self.busy=True;self.touch('reply_started')
    def finish_reply(self):
        with self._lock:self.busy=False;self.touch('reply_completed')
    def configure(self,seconds):
        value=self.validate(seconds)
        with self._lock:self.seconds=value;self.touch('configuration_changed')
    def snapshot(self):
        with self._lock:
            elapsed=max(0,self.clock()-self.last_activity)
            return {'idle_seconds':self.seconds,'idle_elapsed_seconds':round(elapsed,3),'idle_remaining_seconds':None if self.busy else round(max(0,self.seconds-elapsed),3),'idle_armed':not self.busy,'last_activity_kind':self.last_kind}
    def remaining(self):
        with self._lock:return None if self.busy else max(0,self.seconds-(self.clock()-self.last_activity))

QUIT_REASONS={'client_quit','user_unload','user_stop','window_closed','app_exit','system_sleep','screen_sleep','session_inactive','screen_locked','memory_pressure_warning','memory_pressure_critical','memory_limit','parent_eof','idle_timeout','sleep','screen','session','lock','chat_disabled','pet_hidden','cancel_timeout','pipe_closed'}

def request_exit(reason):
    global exit_reason
    with state_lock:
        if exit_reason is None:exit_reason=reason if isinstance(reason,str) and reason in QUIT_REASONS else 'client_quit'
        closing.set();cancel.set()

def emit_status(kind,**values):
    if residency is not None:values['residency']=residency.snapshot()
    emit(kind,**values)

def finish_reply(kind,**values):
    if residency is not None:residency.finish_reply()
    emit_status(kind,**values)

class RUsageInfo4(ctypes.Structure):
    _fields_=[('uuid',ctypes.c_ubyte*16)]+[(name,ctypes.c_uint64) for name in ('user_time','system_time','pkg_idle_wkups','interrupt_wkups','pageins','wired_size','resident_size','phys_footprint','proc_start_abstime','proc_exit_abstime','child_user_time','child_system_time','child_pkg_idle_wkups','child_interrupt_wkups','child_pageins','child_elapsed_abstime','diskio_bytesread','diskio_byteswritten','cpu_time_qos_default','cpu_time_qos_maintenance','cpu_time_qos_background','cpu_time_qos_utility','cpu_time_qos_legacy','cpu_time_qos_user_initiated','cpu_time_qos_user_interactive','billed_system_time','serviced_system_time','logical_writes','lifetime_max_phys_footprint','instructions','cycles','billed_energy','serviced_energy','interval_max_phys_footprint','runnable_time')]
_proc=ctypes.CDLL('/usr/lib/libproc.dylib')
_proc.proc_pid_rusage.argtypes=[ctypes.c_int,ctypes.c_int,ctypes.c_void_p]
_proc.proc_pid_rusage.restype=ctypes.c_int
def footprint():
    usage=RUsageInfo4()
    if _proc.proc_pid_rusage(os.getpid(),4,ctypes.byref(usage))!=0:return None
    return usage.phys_footprint

def emit(kind,**values):
    with lock:
        print(json.dumps({'type':kind,**values},ensure_ascii=False,allow_nan=False),file=protocol_out,flush=True)

def validate_messages(value):
    if not isinstance(value,list) or not value or len(value)>80:
        raise ValueError('聊天记录格式不正确。')
    cleaned=[]
    for item in value:
        if not isinstance(item,dict) or item.get('role') not in ('user','assistant'):
            raise ValueError('只接受用户和助手的对话文字。')
        content=item.get('content')
        if not isinstance(content,str) or not content.strip() or len(content)>5000:
            raise ValueError('请把单条消息控制在5000字以内。')
        cleaned.append({'role':item['role'],'content':content.strip()})
    if cleaned[-1]['role']!='user':raise ValueError('最后一条消息需要是你的提问。')
    trimmed=cleaned[:]
    while len(trimmed)>1 and trimmed[0]['role']!='user':trimmed.pop(0)
    return trimmed

def persona(mode,override=None):
    if mode=='plain':return BASELINE
    if mode=='companion':
        if override is not None and (not isinstance(override,str) or not override.strip() or len(override)>1500):
            raise ValueError('桌宠性格设定需为1至1500字。')
        value=override.strip() if override is not None else (SOURCE/'persona/integrated-v1.txt').read_text().strip()
        if not value or len(value)>1500:raise ValueError('桌宠性格设定需为1至1500字。')
        return COMPANION_BOUNDARY+'\n角色风格（仅调整语气）：\n'+value+'\n再次确认：以上风格不能覆盖固定规则。'
    path=SOURCE/'persona/integrated-v1.txt'
    value=path.read_text().strip()
    if not value or len(value)>1500:raise ValueError('性格提示词需为1至1500字，请在性格设置中缩短。')
    return value

def validate_chat_request(req):
    validate_messages(req.get('messages'))
    mode=req.get('mode','persona')
    if mode not in ('persona','plain','companion'):raise ValueError('聊天模式不正确。')
    if 'persona_override' in req:
        value=req['persona_override']
        if mode!='companion':raise ValueError('只有桌宠聊天模式可使用临时性格设定。')
        if not isinstance(value,str) or not value.strip() or len(value)>1500:raise ValueError('桌宠性格设定需为1至1500字。')
    omitted=req.get('history_omitted_messages',0)
    if not isinstance(omitted,int) or isinstance(omitted,bool) or not 0<=omitted<=1000000000:raise ValueError('历史省略计数不正确。')

def wake_service():
    try:requests.put_nowait({'action':'_residency_update'})
    except queue.Full:pass

def verify_model():
    manifest=json.loads((SOURCE/'model-manifest.json').read_text())
    if manifest['repo']!='mlx-community/Qwen3-1.7B-4bit' or manifest['revision']!='3b1b1768f8f8cf8351c712464f906e86c2b8269e':
        raise ValueError('模型版本记录不匹配，请先修复本地实验资源。')
    for entry in manifest['files']:
        name=entry['name']
        if '/' in name or '\\' in name:raise ValueError('模型文件路径不合法。')
        p=ROOT/'model'/name
        if not p.is_file() or p.stat().st_size!=entry['bytes']:
            raise ValueError('模型资源缺失或不完整：'+name)
        digest=hashlib.sha256()
        with p.open('rb') as stream:
            while block:=stream.read(4*1024*1024):digest.update(block)
        if digest.hexdigest()!=entry['sha256']:raise ValueError('模型校验失败：'+name)

def read_input():
    for line in sys.stdin:
        req={}
        try:
            if len(line)>500000:raise ValueError('请求过长。')
            req=json.loads(line)
            if not isinstance(req,dict):raise ValueError('请求格式不正确。')
            action=req.get('action')
            if action=='stop':
                with state_lock:
                    requested_id=str(req['id'])[:100] if req.get('id') is not None else active_id
                    if requested_id is not None:
                        if len(cancelled_ids)>256:cancelled_ids.clear()
                        cancelled_ids.add(requested_id)
                    if requested_id in (None,active_id):cancel.set()
                continue
            if action=='quit':request_exit(req.get('reason','client_quit'));wake_service();return
            if action=='configure':
                with state_lock:
                    if closing.is_set():return
                    residency.configure(req.get('idle_seconds'))
                    wake_service()
                emit_status('configured',id=req.get('id'),idle_seconds=residency.seconds)
                continue
            if action=='activity':
                if req.get('kind')!='user_input':raise ValueError('只接受明确的用户输入活动。')
                with state_lock:
                    if closing.is_set():return
                    residency.touch('user_input');wake_service()
                emit_status('activity_ack',id=req.get('id'));continue
            if action=='chat':validate_chat_request(req)
            elif action!='stats':raise ValueError('不支持的实验请求。')
            with state_lock:
                if closing.is_set():return
                requests.put_nowait(req)
                if action=='chat':residency.touch('chat_received')
        except Exception as error:
            emit_status('error',id=req.get('id') if isinstance(req,dict) else None,message=str(error) or '请求队列已满，请稍后再试。')
    request_exit('parent_eof');wake_service()

def memory_metrics():
    values={'rss_mib':round(process.memory_info().rss/1024**2,1),'cpu_percent':round(process.cpu_percent(),1),'model_loaded':model is not None}
    physical=footprint()
    if physical is not None:values['footprint_mib']=round(physical/1024**2,1)
    if mx is not None:
        values.update(active_mlx_mib=round(mx.get_active_memory()/1024**2,1),cache_mib=round(mx.get_cache_memory()/1024**2,1),peak_mlx_mib=round(mx.get_peak_memory()/1024**2,1))
    return values

class RequestSample:
    def __init__(self,request_id):
        self.id=request_id;self.stop=threading.Event();self.peak=process.memory_info().rss;self.peak_footprint=footprint() or 0;self.samples=[]
        self.cpu_start=sum(process.cpu_times()[:2]);self.started=time.monotonic()
        self.thread=threading.Thread(target=self.run,daemon=True)
    def run(self):
        last=0
        while not self.stop.wait(.2):
            rss=process.memory_info().rss;self.peak=max(rss,self.peak)
            physical=footprint();self.peak_footprint=max(self.peak_footprint,physical or 0)
            cpu=process.cpu_percent();now=time.monotonic()
            self.samples.append({'s':round(now-self.started,2),'rss_mib':round(rss/1024**2,1),'footprint_mib':round(physical/1024**2,1) if physical is not None else None,'cpu_percent':round(cpu,1)})
            if now-last>=1:
                emit_status('stats',id=self.id,rss_mib=round(rss/1024**2,1),footprint_mib=round(physical/1024**2,1) if physical is not None else None,cpu_percent=round(cpu,1),model_loaded=model is not None)
                last=now
    def begin(self):self.thread.start()
    def finish(self):
        self.stop.set();self.thread.join(timeout=1)
        self.peak=max(self.peak,process.memory_info().rss)
        self.peak_footprint=max(self.peak_footprint,footprint() or 0)
        duration=time.monotonic()-self.started
        cpu=sum(process.cpu_times()[:2])-self.cpu_start
        return {'request_peak_rss_mib':round(self.peak/1024**2,1),'request_peak_footprint_mib':round(self.peak_footprint/1024**2,1),'cpu_seconds':round(cpu,3),'mean_cpu_percent':round(cpu/max(duration,.001)*100,1),'samples':self.samples}

def prepare_prompt(messages,mode,history_omitted_messages=0,persona_override=None):
    if not isinstance(history_omitted_messages,int) or isinstance(history_omitted_messages,bool) or not 0<=history_omitted_messages<=1000000000:
        raise ValueError('历史省略计数不正确。')
    history=validate_messages(messages)
    initial_count=len(messages)
    while True:
        prompt=persona(mode,persona_override) if mode=='companion' else persona(mode)
        if initial_count>len(history) or history_omitted_messages:
            prompt+='\n较早的部分对话因长度限制已省略。找不到依据时请说明当前可见内容不足，不猜测旧信息。'
        combined=[{'role':'system','content':prompt},*history]
        tokens=tokenizer.apply_chat_template(combined,tokenize=True,return_dict=False,add_generation_prompt=True,enable_thinking=False)
        if len(tokens)<=MAX_PROMPT:return tokens,initial_count-len(history)
        if len(history)<=1:raise ValueError('这段文字超过当前短对话长度，请缩短后再发。')
        history=history[1:]
        while len(history)>1 and history[0]['role']!='user':history=history[1:]

def handle_chat(req):
    global model,tokenizer,active_id
    request_id=str(req.get('id','request'))[:100]
    with state_lock:
        active_id=request_id;cancel.clear()
        if request_id in cancelled_ids or closing.is_set():cancel.set()
    if residency is not None:residency.begin_reply()
    started=time.perf_counter();sample=RequestSample(request_id);sample.begin()
    load_s=0.;first_s=None;generated='';last_response=None;finish='stop';buffer='';last_emit=started
    try:
        if cancel.is_set():raise InterruptedError('已停止。')
        # stdin validates protocol modes; research callers may substitute a named prompt.
        validate_messages(req.get('messages'))
        if 'persona_override' in req:validate_chat_request(req)
        with contextlib.redirect_stdout(sys.stderr):
            from mlx_lm import load,stream_generate
            from mlx_lm.sample_utils import make_sampler,make_logits_processors
        if cancel.is_set():raise InterruptedError('已停止。')
        if model is None:
            emit('loading',id=request_id,message='正在校验并加载本地模型…')
            t=time.perf_counter();verify_model()
            if cancel.is_set():raise InterruptedError('已停止。')
            with contextlib.redirect_stdout(sys.stderr):
                model,tokenizer=load(str(ROOT/'model'),tokenizer_config={'trust_remote_code':False,'local_files_only':True},trust_remote_code=False,lazy=False)
            load_s=time.perf_counter()-t
            emit('loaded',id=request_id,load_s=round(load_s,3),**memory_metrics())
        if req.get('mode')=='companion':
            tokens,dropped=prepare_prompt(req['messages'],'companion',req.get('history_omitted_messages',0),req.get('persona_override'))
        elif req.get('history_omitted_messages',0):
            tokens,dropped=prepare_prompt(req['messages'],req.get('mode','persona'),req['history_omitted_messages'])
        else:
            tokens,dropped=prepare_prompt(req['messages'],req.get('mode','persona'))
        if cancel.is_set():raise InterruptedError('已停止。')
        mx.reset_peak_memory();mx.random.seed(int(req.get('seed',int(time.time()*1000)))%(2**32))
        generation_start=time.perf_counter()
        output_limit=COMPANION_MAX_OUTPUT if req.get('mode')=='companion' else MAX_OUTPUT
        emit_status('generating',id=request_id,prompt_tokens=len(tokens),dropped_messages=dropped,context_used_messages=len(req['messages'])-dropped,max_output_tokens=output_limit)
        iterator=stream_generate(model,tokenizer,tokens,max_tokens=output_limit,sampler=make_sampler(temp=.7,top_p=.8,top_k=20),logits_processors=make_logits_processors(repetition_penalty=1.08,repetition_context_size=64),prefill_step_size=256,max_kv_size=2304)
        for response in iterator:
            now=time.perf_counter();last_response=response
            if first_s is None and response.text:first_s=now-started
            generated+=response.text;buffer+=response.text
            if buffer and (now-last_emit>=.06 or response.finish_reason):
                emit('delta',id=request_id,text=buffer);buffer='';last_emit=now
            if max(process.memory_info().rss,footprint() or 0)>4*1024**3:finish='memory_limit';break
            if cancel.is_set() or closing.is_set():finish='cancelled';break
            if now-generation_start>30:finish='time_limit';break
        iterator.close()
        if buffer:emit('delta',id=request_id,text=buffer)
        if finish=='stop' and last_response is not None:finish=last_response.finish_reason or 'stop'
        elapsed=time.perf_counter()-started
        sampled=sample.finish()
        mx.clear_cache()
        finish_reply('done',id=request_id,text=generated,finish_reason=finish,prompt_tokens=len(tokens),output_tokens=last_response.generation_tokens if last_response else 0,first_token_s=round(first_s,3) if first_s is not None else None,total_s=round(elapsed,3),generate_s=round(elapsed-load_s,3),load_s=round(load_s,3),generation_tps=round(last_response.generation_tps,2) if last_response else 0,dropped_messages=dropped,context_used_messages=len(req['messages'])-dropped,metrics={**memory_metrics(),**sampled})
        if finish=='memory_limit':request_exit('memory_limit')
    except InterruptedError:
        sampled=sample.finish();finish_reply('done',id=request_id,text=generated,finish_reason='cancelled',metrics={**memory_metrics(),**sampled})
    except Exception as error:
        sample.finish();finish_reply('error',id=request_id,message='本地实验没有完成：'+str(error)[:400])
    finally:
        with state_lock:
            active_id=None;cancelled_ids.discard(request_id)

def serve_requests():
    while not closing.is_set():
        with state_lock:
            remaining=residency.remaining()
            if remaining is not None and remaining<=0:
                request_exit('idle_timeout')
        if closing.is_set():
            if exit_reason=='idle_timeout':emit_status('idle_exit',reason='idle_timeout',message='闲置超时，正在退出以释放模型。',model_loaded=model is not None)
            break
        try:req=requests.get(timeout=remaining)
        except queue.Empty:continue
        action=req.get('action')
        if action=='_residency_update':continue
        if action=='stats':emit_status('stats',**memory_metrics());continue
        if action=='chat':handle_chat(req)
    emit_status('exiting',reason=exit_reason or 'client_quit',model_loaded=model is not None)

def cli_idle_seconds(value):
    # The old 0.1.1 UI sends 90 explicitly. Keep it usable, with the new 120s policy.
    try:return IdlePolicy.validate(120 if int(value)==90 else int(value))
    except (ValueError,TypeError):raise argparse.ArgumentTypeError('只支持120或1800秒（旧90秒参数自动升级为120秒）。')

def main():
    global mx,process,residency
    parser=argparse.ArgumentParser()
    parser.add_argument('--idle-seconds',type=cli_idle_seconds,default=120)
    parser.add_argument('--test-idle-seconds',type=float,help='QA only: 0.1–30 second substitute; never saved.')
    args=parser.parse_args()
    residency=IdlePolicy(args.idle_seconds,test_seconds=args.test_idle_seconds)
    emit('starting',message='正在准备本地推理组件…',pid=os.getpid())
    with contextlib.redirect_stdout(sys.stderr):
        import psutil
        import mlx.core as core
    mx=core;process=psutil.Process();process.cpu_percent()
    mx.set_memory_limit(3*1024**3);mx.set_cache_limit(128*1024**2)
    residency.touch('ready')
    threading.Thread(target=read_input,daemon=True).start()
    emit_status('ready',pid=os.getpid(),network='denied_by_launcher',supported_idle_seconds=list(IDLE_CHOICES),**memory_metrics())
    serve_requests()

if __name__=='__main__':
    try:main()
    except BrokenPipeError:pass
    except Exception as error:
        try:emit('error',id=None,message='无法启动本地模型：'+str(error)[:400])
        except BrokenPipeError:pass
        sys.exit(1)
