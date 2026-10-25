# Privacy and local data / 隐私与本地数据

## English

**Base application.** The app reads operating-system CPU, memory, storage, sensor, and Bluetooth accessory records to populate the visible status windows. These readings are not sent to a server. Some readings depend on private read-only macOS interfaces and can be missing, delayed, or unavailable after a system update. The app does not actively pair devices, connect to headphones, write sensor values, or control fans.

**Settings.** Preferences belong to the bundle identifier `io.github.bf190t.desktop-companion`. The app remembers options such as language, size, position, and window settings. Its data is separate from applications with other identifiers.

**Local chat.** Chat is optional. The installer contacts the upstream runtime, package, and model hosts only after the user starts installation. Hosting services can receive normal download information such as the network address. The runtime and model are installed under the app's own directory in `~/Library/Application Support`. No account or API key is required. The model worker has its network access denied during inference. It receives the current in-memory chat context and persona, not Bluetooth device records, monitor data, screenshots, or files. Replies are displayed locally. Chat history is not saved as a transcript by the application.

**Voice experiments.** The current speech experiment uses Chinese recognition. Press-to-talk requests the microphone and Speech permissions. Recording is user-triggered and time-limited. The recognizer must support on-device recognition; recognition is refused when this is unavailable. Transcribed text can be reviewed before it is sent to chat. Reading a reply uses a macOS voice on the user's machine. No voice model or prerecorded system-voice sample is bundled. There is no wake-word service or continuous listening mode.

**Diagnostics.** Model status and runtime errors can appear in the inspector. Paths or pieces of entered text may be visible while troubleshooting. Review anything you copy or screenshot before sharing it. The public automated fixtures are synthetic; acceptance output is excluded from the source repository.

**Removal.** Quit the app before removing it. Use the optional component's uninstall control to remove its runtime and weights, or remove the app's own Application Support directory after quitting. Removing the `.app` alone does not necessarily remove preferences or optional downloads. Never remove another application's data as part of this cleanup.

## 简体中文

**基础应用。** 电脑和蓝牙窗口读取系统已有的 CPU、内存、存储、传感器及配件记录，不上传这些读数。部分数据依赖非公开的只读接口，可能缺失、延迟或在系统更新后不可用。程序不主动配对、连接耳机，不写入传感器，也不控制风扇。

**设置。** 应用使用独立标识 `io.github.bf190t.desktop-companion` 保存语言、大小、位置等偏好，与其他应用的数据分开。

**本地聊天。** 只有主动安装可选组件时才会连接运行时、依赖包和模型的上游下载服务；下载服务可能收到正常的网络地址等请求信息。文件保存在本应用的 `~/Library/Application Support` 子目录，无需账号或 API 密钥。正常推理时模型子进程禁止联网，只接收内存中的聊天上下文和性格提示，不接收蓝牙记录、监控数据、截图或文件。应用不把聊天记录保存为会话文件。

**实验语音。** 当前语音实验使用中文识别。按住说话由用户主动触发，并有时长限制；首次使用需要麦克风和语音识别权限。本机识别不可用时拒绝识别，不主动回退云端。转写后可检查文字再发送。朗读调用用户本机的系统声音，不分发声音模型或预录样本。没有唤醒词或持续监听服务。

**诊断与清理。** 调试窗口中的错误信息可能带有文件路径，分享截图和文字前请自行检查。卸载模型可使用可选组件的卸载入口；先退出应用再清理其自己的数据目录。只删除 `.app` 不一定会删除设置或模型，不要误删其他应用的数据。
