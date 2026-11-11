# Privacy and local data / 隐私与本地数据

## English

**Base application.** The app reads operating-system CPU, memory, storage, sensor, and Bluetooth accessory records to populate the visible status windows. These readings are not sent to a server. Some readings depend on private read-only macOS interfaces and can be missing, delayed, or unavailable after a system update. The app does not actively pair devices, connect to headphones, write sensor values, or control fans.

**Settings.** Preferences belong to the bundle identifier `io.github.bf190t.desktop-companion`. The app remembers options such as language, size, position, and window settings. Its data is separate from applications with other identifiers.

**Local chat.** Chat is optional. The installer contacts the upstream runtime, package, and model hosts only after the user starts installation. Hosting services can receive normal download information such as the network address. The runtime and model are installed under the app's own directory in `~/Library/Application Support`. No account or API key is required. The model worker has its network access denied during inference. It receives the current in-memory chat context and persona, not Bluetooth device records, monitor data, screenshots, or files. Replies are displayed locally. Chat history is not saved as a transcript by the application. The prompt also carries the current date and time, and the short "What I remember about you" note: things you clearly said about yourself (a name, likes, work). That note is stored only in the app's preferences on your Mac; you can edit or clear it in the chat window. When a message suggests someone may be in crisis, the app appends a support line chosen from the Mac's region setting; nothing is sent anywhere.

**Voice.** Recording starts and stops only when you click (60 seconds at most). On macOS 26 or newer the system's on-device recognizer is used and only microphone permission is needed; macOS may download its language model once. Earlier systems use on-device Speech recognition and need Speech permission and Dictation. Recognition follows the interface language and never falls back to a cloud service. Transcribed text can be reviewed before it is sent to chat. There is no wake-word service or continuous listening mode.

**Reading voice.** Replies are read by a macOS voice unless you install the optional reading voice. Its installer contacts the upstream runtime, package and model hosts only after you start it. The voice helper then runs on your Mac with network access denied and receives only the text being read. The bundled `companion_voice.wav` is a synthetic voice generated from a text description, not a recording of a person; no system-voice sample is bundled.

**Diagnostics.** Model status and runtime errors can appear in the inspector. Paths or pieces of entered text may be visible while troubleshooting. Review anything you copy or screenshot before sharing it. The public automated fixtures are synthetic; acceptance output is excluded from the source repository.

**Removal.** Quit the app before removing it. Use the optional component's uninstall control to remove its runtime and weights, or remove the app's own Application Support directory after quitting. Removing the `.app` alone does not necessarily remove preferences or optional downloads. Never remove another application's data as part of this cleanup.

## 简体中文

**基础应用。** 电脑和蓝牙窗口读取系统已有的 CPU、内存、存储、传感器及配件记录，不上传这些读数。部分数据依赖非公开的只读接口，可能缺失、延迟或在系统更新后不可用。程序不主动配对、连接耳机，不写入传感器，也不控制风扇。

**设置。** 应用使用独立标识 `io.github.bf190t.desktop-companion` 保存语言、大小、位置等偏好，与其他应用的数据分开。

**本地聊天。** 只有主动安装可选组件时才会连接运行时、依赖包和模型的上游下载服务；下载服务可能收到正常的网络地址等请求信息。文件保存在本应用的 `~/Library/Application Support` 子目录，无需账号或 API 密钥。正常推理时模型子进程禁止联网，只接收内存中的聊天上下文和性格提示，不接收蓝牙记录、监控数据、截图或文件。应用不把聊天记录保存为会话文件。提示里还会带上当前日期时间，以及「记住的关于你」：你在聊天里明确说过的关于自己的事（称呼、喜好、工作等），只存在本机的应用偏好设置里，可在聊天窗口修改或清空。消息里流露出危机时，应用会按系统地区附上求助热线，不会向外发送任何内容。

**语音。** 只在你点一下开始、再点一下停止之间录音（最长 60 秒）。macOS 26 及以上使用系统本机识别，只需麦克风权限，系统可能下载一次语言模型；更早的系统使用本机语音识别，需要语音识别权限并打开「听写」。识别跟随界面语言，从不回退到云端。转写后可检查文字再发送。没有唤醒词或持续监听服务。

**朗读声音。** 默认用 macOS 系统声音朗读回复；另外安装可选朗读声音后用小团的声音。安装程序只在你主动安装时连接运行时、依赖包和模型的上游下载服务；朗读进程在本机运行时禁止联网，只接收要念的文字。随附的 `companion_voice.wav` 是按文字描述生成的合成声音，不是真人录音；不分发系统声音样本。

**诊断与清理。** 调试窗口中的错误信息可能带有文件路径，分享截图和文字前请自行检查。卸载模型可使用可选组件的卸载入口；先退出应用再清理其自己的数据目录。只删除 `.app` 不一定会删除设置或模型，不要误删其他应用的数据。
