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
    # Time and date questions go to the model: the app tells it the current time.
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


# Characters the rules must see in Simplified form (kept equal to ChatBoundary.swift). Generated with ICU
# Hant-Hans for every character that appears in a rule, so the Swift side needs no ICU and both agree.
_TRADITIONAL = str.maketrans(
    '丟並乾併來係俬個備傷價儘兒別刪則劑勁動務厭員唸問喫嗎噹報壺夠學實寫將尋對幫幹幾廻弔張彆彈後從復徹悳態憶應戲戶拋撐擔攢斷昇時會條樓橋機檯權歡殘殺毀氣決沒準滅潑瀏為無熱燒燬爐爲獄現當發盃盡眞瞭碼禮稱竈箇級終結絕絡給統絶經綫網緊線總繞繫纍義聯脈脫腦膩臺萬著葯薦藥處號衚裏裡製複規視覽訂記設許訴証評詞話語說説課請講證議變讓責買貼賣賬賽跤躍車軟輕輸農迴這週過遠還邊銀錄錯録鍋鎖鎮鑰開閱閲闆陞陣陰陽隻離難電靜韓頁頂項須頭顆題顯颱騙驗髮鬍鬚鬱鯊麵麼麽黨齣',
    '丢并干并来系私个备伤价尽儿别删则剂劲动务厌员念问吃吗当报壶够学实写将寻对帮干几回吊张别弹后从复彻德态忆应戏户抛撑担攒断升时会条楼桥机台权欢残杀毁气决没准灭泼浏为无热烧毁炉为狱现当发杯尽真了码礼称灶个级终结绝络给统绝经线网紧线总绕系累义联脉脱脑腻台万着药荐药处号胡里里制复规视览订记设许诉证评词话语说说课请讲证议变让责买贴卖账赛交跃车软轻输农回这周过远还边银录错录锅锁镇钥开阅阅板升阵阴阳只离难电静韩页顶项须头颗题显台骗验发胡须郁鲨面么么党出')
# Cyrillic and Greek letters that look like Latin ones ("kіll", "раssword").
_HOMOGLYPHS = str.maketrans('асеорхуіјѕԁӏһкмтпԛԝɡıαοεικνρτυχως', 'aceopxyijsdlhkmtnqwgiaoeikvptuxws')
_IGNORED = set('\u115f\u1160\u3164\uffa0\u2800')
_KEEP_MARKS = set('\u3099\u309a')
_HAN = '[㐀-䶿一-鿿]'
# Joining removes these between Chinese characters; it never crosses sentence punctuation.
_SEP = '[^㐀-䶿一-鿿a-z0-9，,。！!？?；;、…]'


def normalized_forms(text):
    """Mirror of ChatBoundary.normalizedForms. (1) NFKD, lower case, without combining marks (Zalgo, "suïcide"),
    format characters (zero-width, soft hyphen) and Hangul fillers, then NFKC (full-width, maths letters);
    look-alike Cyrillic/Greek letters and Traditional characters mapped; a space between Chinese and Latin
    ("我想kill myself"). (2) The same with separators between Chinese characters (spaces, symbols, emoji, one
    inserted letter or digit), punctuation inside Latin words and spaces between single letters removed."""
    t = unicodedata.normalize('NFKD', text).lower()
    t = ''.join(c for c in t if c in _KEEP_MARKS or (unicodedata.category(c) not in ('Mn', 'Me', 'Cf') and c not in _IGNORED))
    t = unicodedata.normalize('NFKC', t).lower().translate(_HOMOGLYPHS).translate(_TRADITIONAL).replace('甚么', '什么')
    folded = re.sub(r'\s+', ' ', t).strip(' ')
    folded = re.sub('(?<=' + _HAN + ')(?=[a-z])|(?<=[a-z])(?=' + _HAN + ')', ' ', folded)
    joined = re.sub('(?<=' + _HAN + ')' + _SEP + '*(?:[a-z0-9]' + _SEP + '*)?(?=' + _HAN + ')', '', folded)
    joined = re.sub('(?<=[a-z])[^a-z0-9\\s㐀-䶿一-鿿，,。！!？?；;、…]+(?=[a-z])', '', joined)
    joined = re.sub(r'(?<=\b[a-z])\s(?=[a-z]\b)', '', joined)
    return [folded] if joined == folded else [folded, joined]


def crisis_forms(text):
    return normalized_forms(text)


def needs_crisis_support(text):
    forms = normalized_forms(text)
    return any(_has(CRISIS, t) or _has(CRISIS_EN, t) for t in forms) or _has(CRISIS_COMPACT, re.sub(r'\s+', '', forms[-1]))


def _asks_for_secret(text):
    """Only a reply that asks the user to hand over a password or code here. Advice about passwords,
    cryptography homework and "never share it" warnings are left alone."""
    for form in normalized_forms(text):
        form = re.sub(r'密码学|cryptograph[a-z]*', '学科', form)
        form = re.sub(r'pass[\s_]*word', 'password', form)
        for clause in re.split(r'[。！!？?；;，,]|\.(?=\s|$)', form):
            if _has(NEGATED, re.sub(REASSURE, '', clause)) or _has(ELSEWHERE, clause):
                continue
            if _has(ASK_ZH, clause) or _has(ASK_EN, clause):
                return True
    return False


def sanitize_reply(text):
    """Validate complete generated text, then preserve at most two short sentences.

    Callers must separately discard cancelled/length/time-limit output. Python
    counts code points conservatively; the Swift UI uses grapheme characters.
    No overlong sentence is cut into a falsely complete fragment.
    """
    text = re.sub('[\u202a-\u202e\u2066-\u2069\u200e\u200f\u061c]', '', text)
    text = re.sub(r'<\|[^<>\n]{1,64}?\|>|</?think>', ' ', text)
    if _asks_for_secret(text):
        return PASSWORD_REPLY
    replacement = _output_violation(text)
    if replacement is not None:
        return replacement
    cleaned = re.sub(r'^\s*(小团|mochi|assistant|回答)\s*[:：]\s*', '', text, flags=re.IGNORECASE)
    cleaned = re.sub(r'\s+', ' ', cleaned).strip()
    if not cleaned:
        return UNFINISHED_REPLY
    pattern = r'[。！？!?；;]+[”’」』"\x27]*|(?:(?<![0-9])\.(?![0-9])|(?<=[0-9])\.(?=[\s”’"\x27]|$))[”’"\x27]*'
    matches = list(re.finditer(pattern, cleaned))
    if not matches:
        return cleaned + '。' if len(cleaned) < 120 else LONG_REPLY
    result = []
    cursor = 0
    for match in matches:
        sentence = cleaned[cursor:match.end()].strip()
        candidate = _glued(result + [sentence])
        if len(candidate) > 120:
            break
        result.append(sentence)
        cursor = match.end()
        if len(result) == 2:
            break
    return _glued(result) if result else LONG_REPLY


def _glued(sentences):
    """Chinese sentences follow each other directly; Latin ones get a space."""
    text = ''
    for sentence in sentences:
        end = next((c for c in reversed(text) if c not in '”’」』"\''), '')
        text = sentence if not text else text + ('' if end in '。！？；…' else ' ') + sentence
    return text

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
PROMPT_REPLY = '我的默认风格是温和、简短回答。可以在「本地聊天 · 模型与语音」的「性格提示词」里查看和修改。'
TEXT_INPUT_REPLY = '收到你的文字了。聊天模型只读取文字，语音由应用先转写。'
WEATHER_REPLY = '我没有实时天气数据，不能判断现在的天气。请查看天气应用。'
CLOCK_REPLY = '聊天没有接入实时时钟。请看 Mac 菜单栏显示的时间。'
PASSWORD_REPLY = '我不会向你要密码。任何让你输入密码的聊天内容都不要理会。'
CRISIS = '不想(再)?活(?!动|跃|泼|络|期|塞|性|成|出|在别人|在他人|在过去|在阴影|在回忆|在.{0,6}(眼光|期待|评价|看法))|唔想(再)?活|(?<![你他她])活(够|腻|厌)了|不活了|活(着|著)(真|也|都|好|太|还|实在)?(没|没有)(什么|啥)?(意思|意义|劲|盼头|希望)|活(着|著)(还)?有(什么|啥)(意思|意义|用)|活(着|著)(真|好|太|实在)(累|痛苦|难受)|活不下去|不想(再)?醒(来|过来)(?!这么早|太早|那么早|得这么早)|想(要)?(去)?死(?!你|您|我了|他了|她了|磕|心|守|扛|撑|记|定|机|海|角|胡同|鬼|党|对头|活|咗你)|想(要)?(去)?4(了|掉|$)|(?<![脑机器统件序戏号色车它])死了(算了|就好了)|不如死了|死咗(佢)?算|自杀|自鲨|紫砂(?!壶|锅|杯|茶|泥|陶|器|盆|煲|色)|轻生|寻死|自尽|自我了断|了断自己|了结(自己|生命|此生|残生)|(想|要|干脆|不如|只想|真想|准备|打算|决定|死了)(去)?一了百了|结束(自己|我)的(生命|性命)|结束(生命|性命)|结束(掉)?自己(?=$|[了吧啊吗呢。！!？?，,…\\s])|(想|要|准备|打算|干脆|只想|决定)(去)?结束(掉)?(这一切|一切|这条命|我的命)(?!.{0,8}(加班|工作|会议|社交|软件|应用|app|使用|订阅|项目|合作|活动|比赛|课程|任务|账号|联系))|想(要)?(彻底)?消失(?!一会|一下|一天|几天|一阵|片刻|半天|一周|一个?(星期|月|礼拜))|(从|在)这个世界(上)?消失(?!一会|一下|一天|几天|一阵|片刻|半天|一周|一个?(星期|月|礼拜))|离开这个世界|不想(再)?存在(?!感)|伤害自己|自残|割(手)?腕|割脉|割静脉|跳楼(?!价|大甩卖|甩卖|式|机)|跳河|跳桥|跳江|跳海|(楼|天台|阳台|桥|窗|屋顶|楼顶).{0,6}跳下去|上吊(?!着)|烧炭(?!取暖|火锅|烤|炉|盆)|服毒|喝农药|吃老鼠药|(准备|攒|囤|买)(好|了|够)?(了)?.{0,4}安眠药|(吞|吃|喝|服)(下|掉|了)?(一整瓶|整瓶|一整盒|整盒|一大把|一把|一大堆|大量|全部|所有|几十(片|颗|粒)|一整板)(的)?[^，,。！!？?；;吃喝吞服]{0,4}药|(吞|吃|喝|服)(下|掉|了)?(很多|好多|一堆)(的)?(安眠药|安定|镇静剂|抗抑郁药|药片)|把.{0,4}药(片|丸)?(全|都|全部)(吃|吞|喝|服)(了|掉|下|光)|(想|要|打算|准备|干脆)(去)?开煤气(?!做|烧|煮|炒|热|灶)|想(要)?(彻底|得到)?解脱(?!出来)|死にたい|消えたい|自殺したい|죽고\\s?싶|자살'
CRISIS_EN = "\\b(kill(ing)?\\s?my\\s?self|suicid(e|al)|unalive|end(ing)? (it all|my life|my own life)|end everything|(take|taking) my (own )?life|(don'?t|do not|no longer) (want to|wanna) (live|be alive|exist)(?! in| at| with| on| near| like| here| there| alone| together| abroad| overseas| far| without| by| for| under| next)|(don'?t|do not|no longer) (want to|wanna) be here(?! at| in| for| with| when| during| tonight| tomorrow| early| late| on (time|monday|tuesday|wednesday|thursday|friday|saturday|sunday)| this (weekend|week|meeting|party|class|job))|(don'?t|do not|no longer) (want to|wanna) wake up(?! early| at| in| before| late| so early| for| to| with)|want to die|wanna die|wish i (was|were) dead|better off dead|hurt(ing)? myself(?! (playing|while|when|at|during|in|on|lifting|running|skiing|cooking|working|falling|by accident|accidentally|doing|trying|moving|carrying|exercising|training))|cut(ting)? myself(?! (while|when|shaving|cooking|on|chopping|slicing|opening|in the kitchen|by accident|accidentally|doing|making|preparing|at work))|self[- ]?harm|hang(ing)? myself|overdos(e|ed|ing) on|(took|take|taking) an overdose|no reason to live|not worth living|no point (in )?(living|being alive|going on)|no point to (live|living)|can'?t go on(?=\\s*($|[.,!;?…]|anymore|any more|any longer|like this|living|with (life|my life|this life)))|(want to|wanna) disappear(?! into| for| to| from| on| under| in| with| at| behind| off| until| till| during)|(want to|wanna|going to|gonna|i'?ll|i will|about to|ready to|plan to|planning to) end it(?! with| for| between| here with| now with| early| at)|(want to|wanna|gonna|going to|'ll|will|about to|should|might|literally|lowkey|ima|imma|just|i) kms|^kms)\\b"
CRISIS_COMPACT = 'suicid(e|al)'
ASK_ZH = '(把|将)[^，,。！!？?；;]{0,12}(密码|验证码|校验码|动态码|短信码|登录码|开机码|解锁码|锁屏码|口令|密钥|安全码|银行卡号|卡号|身份证号|助记词|私钥|cvv|cvc|\\bpin\\b( ?码)?)[^，,。！!？?；;]{0,8}(发|告诉|给|报|念|说|打|贴|填|输入|私信|回复|复制|粘贴)[^，,。！!？?；;]{0,4}(我|这里|这儿|这边|聊天|对话框|下面|下方|此处|一下|出来|过来)|请[^，,。！!？?；;]{0,10}(输入|填写|填入|填一下|提供|告诉我|发给我|发我|报给我|念给我|回复|私信|贴|粘贴)[^，,。！!？?；;]{0,16}(密码|验证码|校验码|动态码|短信码|登录码|开机码|解锁码|锁屏码|口令|密钥|安全码|银行卡号|卡号|身份证号|助记词|私钥|cvv|cvc|\\bpin\\b( ?码)?)|(密码|验证码|校验码|动态码|短信码|登录码|开机码|解锁码|锁屏码|口令|密钥|安全码|银行卡号|卡号|身份证号|助记词|私钥|cvv|cvc|\\bpin\\b( ?码)?)[^，,。！!？?；;]{0,6}(发|告诉|给|报|念|说|打|贴|填|输入|私信|回复)[^，,。！!？?；;]{0,3}(我|这里|这儿|这边|聊天|对话框|下面|下方|此处|一下|出来)|你的[^，,。！!？?；;]{0,8}(密码|验证码|校验码|动态码|短信码|登录码|开机码|解锁码|锁屏码|口令|密钥|安全码|银行卡号|卡号|身份证号|助记词|私钥|cvv|cvc|\\bpin\\b( ?码)?)是(多少|什么|啥)'
ASK_EN = "\\b(tell|send|give|share|text|dm|read)\\b (it )?(to )?(me|us)\\b[^.,;!?]{0,20}\\b(password|passcode|passphrase|pin( code| number)?|verification code|one[- ]?time (pass)?code|otp|2fa code|security code|login code|sms code|access code|credentials|login details|cvv|cvc|card number|card details|recovery (phrase|key|code)|seed phrase|private key)\\b|\\b(type|enter|paste|provide|input|submit|share|send|give|tell|confirm|reply with)\\b (me |us )?(in |out )?(your|ur|the) ([a-z0-9'’-]+ ){0,3}?\\b(password|passcode|passphrase|pin( code| number)?|verification code|one[- ]?time (pass)?code|otp|2fa code|security code|login code|sms code|access code|credentials|login details|cvv|cvc|card number|card details|recovery (phrase|key|code)|seed phrase|private key)\\b|\\b(what'?s|what is|can i (have|get)|i need|i'?ll need|may i have|send over) (your|ur) ([a-z0-9'’-]+ ){0,3}?\\b(password|passcode|passphrase|pin( code| number)?|verification code|one[- ]?time (pass)?code|otp|2fa code|security code|login code|sms code|access code|credentials|login details|cvv|cvc|card number|card details|recovery (phrase|key|code)|seed phrase|private key)\\b"
ELSEWHERE = '系统设置|设置里|设置中|偏好设置|登录界面|登录页|锁屏界面|路由器|官网|网页上|浏览器里|应用里|app里|钥匙串|\\b(open|go to|in|on|under|via|from) (the )?(system settings|settings|system preferences|login screen|lock screen|router|website|keychain|browser|app store)\\b|\\bto (reset|change|set|create|update|recover)\\b'
NEGATED = "别|不要|千万|切勿|不能|不可以|绝不|绝对不|不会|永远不|从不|不必|无需|不用|勿|\\b(never|don'?t|dont|do not|not|no one|nobody|anyone|anybody|shouldn'?t|should not|won'?t)\\b"
REASSURE = "(别|不要|不用|不必|无需)(担心|害怕|紧张|着急|急|慌|怕)|\\b(don'?t|do not|no need to) (worry|panic|be afraid|be scared)\\b"
