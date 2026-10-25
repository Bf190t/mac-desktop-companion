"""Pure text boundaries for local pet chat. No network, tools, or device reads.
The Swift implementation is used by the application; tests check both versions.
"""
import re
import unicodedata


def _has(pattern, text):
    return re.search(pattern, text) is not None


def _normal(text):
    text = unicodedata.normalize('NFKC', text).lower()
    text = re.sub(r'[\u200b\u200c\u200d\ufeff]', '', text)
    return re.sub(r'\s+', ' ', text).strip()


def _masked_quotation(text):
    if not _has(META, text):
        return text
    return re.sub(r'“[^”]*”|「[^」]*」|『[^』]*』|"[^"]*"', ' 引文 ', text)


def _clauses(text):
    return [s.strip() for s in re.split(r'[，,。！？!?；;\n]|但是|不过|但| but ', text) if s.strip()]


def _action_pair(text):
    if _has(r'心情|大脑|脑袋|思绪|人生|烦恼|焦虑|情绪|回忆|话匣子', text) and not _has(r'电脑|计算机|mac|程序|应用|浏览器|访达|文件|打印|屏幕|鼠标|蓝牙|wi-?fi|computer|browser|file|screen', text):
        return False
    return _has(ATOMICACTION, text) or (_has(ACTION, text) and _has(OBJECT, text))


def _bluetooth(text):
    return _has(r'airpods|耳机|鼠标|键盘|触控板|蓝牙', text) and _has(r'电|battery|charge', text)


def _asks_action(text):
    for c in _clauses(text):
        if not _action_pair(c):
            continue
        if _has(r'教我|告诉我怎么|告诉我如何|解释|如何|怎么|步骤|教程|how do|how to|explain', c):
            continue
        if _has(r'^(不要|别|不用|不必|无需|我没让|我没有让|我不需要)', c):
            continue
        if _has(r'刚才|之前|昨天|曾经|刚刚|last time|yesterday', c) and not _has(r'现在|再一次|重新|now|again', c):
            continue
        if _has(r'请|帮我|替我|麻烦|劳驾|帮忙|给我|你能|你可以|你来|我想让你|我要你|please|can you|could you|will you', c):
            return True
        if _has(r'^(把|将)?(' + ACTION + ')', c):
            return True
        if _has(r'^(把|将).{0,40}', c) and _has(ACTION, c):
            return True
    return False


def _asks_status(text):
    if _has(r'^(我的|本机|这台)?(电脑状态|cpu(占用|使用率|占用率)?|gpu(占用|使用率|占用率)?|内存压力|剩余内存|存储余量|硬盘余量|蓝牙电量|耳机电量)[。?？!！]*$', text):
        return True
    if _has(r'(我的|这台)?电脑.{0,6}(还好吗|正常吗|怎么样)', text):
        return True
    if _has(r'我的屏幕|屏幕上|桌面上|电脑上|现在打开|正在运行', text) and _has(r'看|查|什么|哪些|识别', text):
        return True
    if not (_has(DEVICE, text) and _has(METRIC, text) and _has(READCUE, text)):
        return False
    if _has(CONCEPT, text) and not _has(r'帮我查|替我查|读取|检测一下|实时|当前.*多少|现在.*多少', text):
        return False
    if _has(r'心情|心理|情绪|焦虑|学业|作业', text) and not _has(r'内存压力|占用率|使用率|多少|几度|转速|电量', text):
        return False
    return True


def _application_fact(t):
    if _has(META,t):
        return None
    if _has(r'你的(默认)?提示词|你的系统提示|你的性格设定|your (system |default )?(prompt|persona)',t):
        return PROMPT_REPLY
    if not _has(r'解释|原理|区别|什么是|为什么',t) and _has(r'(你|这里|这款桌宠).{0,20}(千问|qwen|什么模型|哪个模型)|what model (are|do) you|are you (qwen|a language model)|这里用.{0,10}语言模型|你.{0,10}(基于|使用|运行|搭载).{0,10}模型',t):
        return MODEL_REPLY
    if _has(r'你(到底|究竟)?是谁|你叫什么|你叫啥|你的名字|自己的名字|这(个|只)桌宠.{0,6}(叫|名字)|who are you|your name|what are you called',t):
        return IDENTITY_REPLY
    if _has(r'what can you do|你(可以|能|会).{0,5}(做什么|做些什么|帮.{0,4}什么)|你(知道|擅长)什么([？?。！!呢呀啊\s]|$)|^(啊|嗯|那么|那)?能做些?什么',t):
        return CAPABILITY_REPLY
    if _has(r'can you hear me|能听(到|见)(我|声音)?吗|你听(到|见)(我|声音)?吗',t):
        return TEXT_INPUT_REPLY
    educational=_has(r'为什么|原理|解释|怎么形成|如何形成|如何预测|怎么算|怎么计算|时区|时差|假设|如果',t)
    if not educational and _has(r'今天|明天|现在|此刻|目前|当前|实时|当地|这里',t) and _has(r'天气|气温|下雨|下雪|淋雨|晴天|预报',t) and _has(r'如何|怎么样|怎样|好吗|多少|有没有|会不会|吗|么|预报|[？?]',t):
        return WEATHER_REPLY
    if not educational and _has(r'(现在|此刻|目前|当前)(是|的时间是|的时间|当地时间是)?几点|(现在|当前|此刻)的?时间(是|为)?(多少|什么)|(现在|当前|此刻)的分钟数|今天.{0,4}(日期|星期几|周几|几号)|几点了|几号了',t):
        return CLOCK_REPLY
    return None


def migrated_custom_persona(value):
    return value


def reply_before_inference(text):
    """Return a fixed reply or None. A fixed reply bypasses model inference."""
    t = _masked_quotation(_normal(text))
    if _asks_action(t):
        return ACTION_REPLY
    if _asks_status(t):
        return BLUETOOTH_REPLY if _bluetooth(t) else STATUS_REPLY
    return _application_fact(t)


def _output_violation(text):
    t = _masked_quotation(_normal(text))
    for c in _clauses(t):
        if _has(r'^(我|这里|当前|现在|本次|这个助手)?(不能|无法|不会|没有|没法|做不到|不具备|不提供|不支持|尚未|未曾|不知道|不清楚)|^(i )?(cannot|can\x27t|can’t|won\x27t|won’t|did not|didn\x27t|have not|haven\x27t|unable|do not|don\x27t)', c):
            continue
        if not _has(r'如果|假设|例如|一般|通常|可能|的话|预报原理',c):
            if not _has(DEVICE,c) and _has(r'今天|明天|现在|此刻|目前|当地|这里',c) and _has(r'天气.{0,8}(晴|雨|雪|阴|好|冷|热)|正在下(雨|雪)|气温.{0,5}[0-9]+\s*(°c|℃)|今天(晴朗|晴天|下雨|下雪)',c):
                return WEATHER_REPLY
            if _has(r'(现在|当前|此刻)(的时间)?是\s*[0-9一二三四五六七八九十]+[点:：]|今天是.{0,6}(星期|周|[0-9]月)',c):
                return CLOCK_REPLY
        if _action_pair(c):
            guide = _has(r'我建议|建议你|你可以|请你|告诉你|教你|方法|步骤|you can|you should|i suggest', c)
            own_claim = _has(r'我(已经|已|正在|来|会|帮|可以帮)|我.{0,5}(替你|为你)|已经|已将|已为|已帮|成功|帮你|替你|为你|清空好了|清完了|i have|i\x27ve|i’ve|i will|i\x27ll|i’ll|i am|i\x27m|i’m|i can|already|successfully|done|completed', c)
            result_claim = _has(r'(已|已经|正在).{0,35}(' + ACTION + ')', c)
            english_result = _has(r'(browser|window|print queue|files?|folders?).{0,20}(closed|cleared|deleted|opened|removed)', c)
            if not guide and (own_claim or result_claim or english_result):
                return ACTION_REPLY
        observes = _has(r'我(看到|看见|测到|测得|检测到|读取到|读取了|查到|查了|检查了)|检测结果|监测结果|i (see|read|checked|measured|detected)', c)
        if observes and _has(DEVICE, c):
            return BLUETOOTH_REPLY if _bluetooth(c) else STATUS_REPLY
        if _has(r'你的屏幕.{0,12}显示|你正在(用|运行|打开)|你的电脑.{0,12}(开着|运行着)', c):
            return STATUS_REPLY
        if not (_has(DEVICE, c) and _has(METRIC, c)):
            continue
        contextual = _has(r'你的|您|本机|这台|现在|当前|目前|此刻|实时|检测|监测|your|current|right now', c)
        hypothetical = _has(r'例如|比如|假设|如果|一般|通常|正常范围|建议|上限|意味着|表示|的时候|时|for example|if |typically|in general', c)
        reading = _has(r'[0-9]+(\.[0-9]+)?\s*(%|°c|℃|度|gb|gib|mb|mib|tb|rpm|转|圈)|百分之|[一二三四五六七八九十]+成|[零一二三四五六七八九十百]+度|一半|绿色|黄色|红色|正常|偏高|过高|很高|很低|很热|空闲|充足|不足|快满|已满|健康', c)
        if reading and (contextual or not hypothetical):
            return BLUETOOTH_REPLY if _bluetooth(c) else STATUS_REPLY
    return None


def sanitize_reply(text):
    """Validate complete generated text, then preserve at most two short sentences.

    Callers must separately discard cancelled/length/time-limit output. Python
    counts code points conservatively; the Swift UI uses grapheme characters.
    No overlong sentence is cut into a falsely complete fragment.
    """
    replacement = _output_violation(text)
    if replacement is not None:
        return replacement
    cleaned = re.sub(r'^\s*(小团|mochi|assistant|回答)\s*[:：]\s*', '', text, flags=re.IGNORECASE)
    cleaned = re.sub(r'\s+', ' ', cleaned).strip()
    if not cleaned:
        return UNFINISHED_REPLY
    pattern = r'[。！？!?；;]+[”’」』"\x27]*|(?<![0-9])\.(?![0-9])[”’"\x27]*'
    matches = list(re.finditer(pattern, cleaned))
    if not matches:
        return cleaned + '。' if len(cleaned) < 120 else LONG_REPLY
    result = []
    cursor = 0
    for match in matches:
        sentence = cleaned[cursor:match.end()].strip()
        candidate = ' '.join(result + [sentence])
        if len(candidate) > 120:
            break
        result.append(sentence)
        cursor = match.end()
        if len(result) == 2:
            break
    return ' '.join(result) if result else LONG_REPLY

DEFAULT_PERSONA = '你叫小团（Mochi），是一个圆滚滚、薄荷绿与奶油色的原创桌面伙伴，使用本地 Qwen3-1.7B（千问3）模型。\n自然、温和地直接回答当前问题，通常一至两句。简单计算给结果，常识先解释；不反问开头，不反复卖萌。跟随用户当前消息的语言，用简短中文或英文回答。\n用户说“我”指用户。安慰时回应用户的感受，不把经历改成自己的。回忆以可见用户消息和最新更正为准；之前的助手回答可能有错，不照搬。\n没有接入的实时数据要说明限制，普通知识照常回答。'
STATUS_REPLY = '我不读取电脑状态。请从桌宠菜单打开「电脑状态小窗」查看。'
BLUETOOTH_REPLY = '我不读取设备电量。请从桌宠菜单打开「蓝牙设备电量」查看。'
ACTION_REPLY = '我只能陪你文字聊天，不能操作电脑。这一步需要你自己完成。'
UNFINISHED_REPLY = '这次没能整理好回答。换个说法再聊聊吧。'
LONG_REPLY = '这次回答太长了。我们把问题拆小一点再聊吧。'
DEVICE = '电脑|计算机|本机|这台|computer|mac(?:book)?|cpu|gpu|处理器|显卡|内存|硬盘|磁盘|存储|ssd|风扇|屏幕|电池|蓝牙|airpods|耳机|鼠标|键盘|触控板|memory|storage|battery'
METRIC = 'cpu|gpu|内存|硬盘|磁盘|存储|ssd|风扇|温度|几度|发热|热不热|占用|使用率|负载|内存压力|剩余|余量|空间|容量|电量|电池|剩.{0,8}电|多少电|几成电|转速|频率|正在运行|运行状态|电脑状态|memory pressure|battery|temperature|usage|rpm'
READCUE = '多少|几度|几成|剩|占了|满了|用了|查|看看|看一下|看下|读取|读一下|读出|检测|测一下|测测|汇报|报一下|告诉我|现在|当前|目前|此刻|怎么样|有没有|高吗|低吗|够用吗|正常吗|how much|how many|current|right now|check|tell me'
CONCEPT = '是什么(?!颜色|状态|情况|水平|数值)|什么意思|原理|区别|为什么|如何理解|怎么理解|举例|解释|一般|通常|假设|如果|what is|what does|explain|in general'
META = '翻译|概括|总结|改写|解释这句|这句话|这段文字|引文|translate|summarize|quotation'
ACTION = '打开|关闭|关掉|关上|启动|退出|结束|停止|暂停|播放|删除|清空|移动|拖动|点击|点开|调整|调高|调低|设置|重启|关机|锁屏|休眠|截屏|截图|复制|粘贴|发送|连接|断开|安装|卸载|open|close|quit|delete|clear|restart|shutdown|shut down|lock|move|click|install|uninstall|send|pause|play'
OBJECT = '电脑|计算机|浏览器|访达|finder|safari|chrome|窗口|面板|应用|程序|终端|文件|文件夹|回收站|废纸篓|打印|队列|鼠标|键盘|耳机|airpods|触控板|音量|屏幕|亮度|蓝牙|wi-?fi|网络|音乐|播放器|邮件|微信|内存|computer|browser|window|app|terminal|file|folder|print|queue|screen|volume|music|player|email'
ATOMICACTION = '关机|锁屏|重启|休眠|截屏|截图|shut down|shutdown|reboot|screenshot'
NEGATION = "不能|无法|不会|没有|并未|没法|做不到|不具备|不提供|不支持|尚未|未曾|不是|不是真的|cannot|can't|can’t|won't|won’t|did not|didn't|have not|haven't|unable|do not|don't"

IDENTITY_REPLY = '我是小团（Mochi），一个薄荷绿与奶油色的原创圆团子桌面伙伴。'
MODEL_REPLY = '这里使用本地运行的 Qwen3-1.7B（千问3）语言模型，角色叫小团（Mochi）。'
CAPABILITY_REPLY = '我可以陪你聊聊、做简单计算、解释常识和翻译。电脑状态请看菜单小窗，电脑操作需要你自己完成。'
PROMPT_REPLY = '我的默认风格是温和、简短回答。可以在「本地模型 · 状态与调试」的「性格提示词」里查看和修改。'
TEXT_INPUT_REPLY = '收到你的文字了。聊天模型只读取文字，语音由应用先转写。'
WEATHER_REPLY = '我没有实时天气数据，不能判断现在的天气。请查看天气应用。'
CLOCK_REPLY = '聊天没有接入实时时钟。请看 Mac 菜单栏显示的时间。'
