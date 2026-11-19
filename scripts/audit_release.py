#!/usr/bin/env python3
"""Targeted release-content audit. This is not a vulnerability scanner.

Modes:
  source   a checkout (build output skipped; audit the final app/ZIP separately)
  app      a built .app bundle
  zip      the release archive (read in memory, never extracted)
  history  every blob reachable from any ref of a git repository (`git rev-list --all`)

Read-only: it never writes archives to disk (nested ones are read in memory, with size and depth
limits) and never prints matched text, private terms, or secrets. A path that contains a private term
is shown as '<path withheld #N>' in every finding and in the --json manifest.

Private terms (names that must never ship) are not written in this repository. Supply them with
--deny-terms-file PATH (one term per line, '#' comments; keep the file outside the repository) or
the RELEASE_DENY_TERMS environment variable (newline-separated; CI reads it from a repository
secret and runs the generic rules alone when it is empty). A term matches case-insensitively after
folding (NFKD, combining marks / variation selectors / format characters dropped, common Cyrillic
and Greek look-alike letters mapped to Latin, common traditional Chinese forms mapped to simplified,
NFKC), also with whitespace and punctuation removed ("A b-c" matches "abc"), in UTF-8, UTF-16,
GB18030 and Big5 text, in Base64 runs inside text files, in PNG text chunks, inside nested archives
(zip, gzip, bzip2, xz, tar) and in file names (zip names stored without the UTF-8 flag, as ditto
writes them, are decoded as UTF-8 too).

Audio: the only audio that may ship is the pinned companion voice. Any other audio is rejected by
file suffix and by content signature (WAV/RF64, AIFF/AIFC, MP3/ID3, ADTS AAC, FLAC, Ogg/Opus, CAF,
MP4/M4A/M4B, .snd/.au, ...), wherever the signature sits in the file. The retired-voice and
private-asset hash lists only catch byte-identical copies; the signature rule is what catches a
transcoded or edited copy.

Limits (by design; source mode covers them): in binary files (executables, media) ASCII terms shorter
than 5 characters are not matched and ASCII terms are not matched with punctuation removed, so a short
string compiled into a Swift binary (Swift keeps strings of up to 15 bytes inline in instructions) is
not found there; the source audit sees it. Archives in formats the standard library cannot read (7z,
rar, xar, zstd, dmg, ...) are reported but not scanned inside.
"""
from __future__ import annotations

import argparse
import base64
import bz2
import gzip
import hashlib
import io
import json
import lzma
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import stat
import subprocess
import sys
import tarfile
import unicodedata
import zipfile
import zlib

SOURCE_SKIP = {'.git', 'build', 'dist', '__pycache__', '.pytest_cache', '.venv'}
FORBIDDEN_COMPONENTS = {
    'reference', 'references', 'preview', 'previews', 'private', 'local-assets',
    'qa', '.qa', '.model-test', 'python-base', 'site-packages', 'venv',
}
AUDIO_SUFFIXES = {
    '.wav', '.wave', '.aif', '.aiff', '.aifc', '.mp3', '.mp2', '.m4a', '.m4b', '.m4p', '.m4r', '.mp4',
    '.m4v', '.mov', '.3gp', '.3g2', '.caf', '.flac', '.ogg', '.oga', '.opus', '.spx', '.aac', '.adts',
    '.au', '.snd', '.wma', '.asf', '.amr', '.mka', '.mkv', '.webm', '.wv', '.ape', '.ac3',
}
FORBIDDEN_SUFFIXES = {
    '.safetensors', '.gguf', '.onnx',
    '.pem', '.key', '.mobileprovision', '.pyc', '.pyo', '.log',
} | AUDIO_SUFFIXES
ARCHIVE_SUFFIXES = {
    '.zip', '.gz', '.tgz', '.bz2', '.tbz', '.tbz2', '.xz', '.txz', '.lzma', '.zst', '.lz4', '.z',
    '.7z', '.rar', '.tar', '.dmg', '.pkg', '.xar', '.aar', '.cpio', '.jar', '.whl', '.egg', '.ipa', '.apk',
}
# Generic names of pre-publication assets. Renamed copies are caught by PRIVATE_ASSET_SHA256, and
# names that would identify them are left to the private deny-terms file.
FORBIDDEN_ASSETS = {'Idle.png', 'Blink.png', 'VoiceSample.aiff', 'AssetManifest.json',
                    'python-runtime-provenance.json'}
SOURCE_TOP = {'app', 'chat', 'voice', 'scripts', 'tests', 'docs', '.github'}
SOURCE_ROOT_FILES = {
    'README.md', 'README.zh-CN.md', 'LICENSE', 'THIRD_PARTY_NOTICES.md',
    'SECURITY.md', 'CONTRIBUTING.md', '.gitignore', '.gitattributes',
    'CHANGELOG.md', 'VERSION',
}
PUBLIC_BUNDLE_ID = 'io.github.bf190t.desktop-companion'

# The one audio file that may ship: the companion's synthetic reading voice, generated with a
# built-in Qwen3-TTS speaker (Apache-2.0); see voice/companion_voice.json. It is pinned twice: the
# file must hash to COMPANION_VOICE_SHA256 *and* to the sha256 in its JSON. Changing the voice
# therefore means changing this line too, so a reviewer sees it. Any other audio, under any name and
# in any format, is rejected by audio_signature() ('audio-content') and by AUDIO_SUFFIXES. The built
# app and the release ZIP carry no other sound (no alert sounds of their own), so there is nothing
# else to allow.
ALLOWED_AUDIO = {'voice/companion_voice.wav', 'Contents/Resources/Voice/companion_voice.wav'}
COMPANION_VOICE_SHA256 = '8e7265e737c555733b2fce158273328bf11a1d195163605f904fc6bae4a2a06c'
# Voices that were replaced and must never ship again. A hash only matches a byte-identical copy (a
# renamed one included); an edited or transcoded copy is caught by the audio-content rule instead.
RETIRED_VOICE_SHA256 = {
    '563bc296fb82a61737136e070621e52d1d154c6d7e820802c94479a19d486e14',  # reading voice of 0.2.0
}
# Pre-publication art and audio that never belonged in the public project (hashes only).
PRIVATE_ASSET_SHA256 = frozenset('''
122aa9b95d4304d9290f9bd1f2f2c3ff2729603477acd1262d1d4363656ed047
e20e65d02c00f7d6618468ef79757d2ec7edee57217d821f3e6a0be4ecaf9141
da847251bfd3d6d3aa6022dbfc820640342f27c37e7d2353e5f7b224d9f6c435
e1347dbcbc654c5ad2213f91c6d3320b0da361a75a46a8f4e9fadf9995eb6853
bdea1301d1ffb8cc7405b8829ee84d7432fad9975af0cc51b1448feb9fe1da17
6f38a6948b288a91a2b12bd40277e95936db8a79e1e3179914a4e7d6df8b254f
c56c4fafb8e44f9b0c9017a2ad6a24ebd34909b69e964c6250a2068941cb105b
2123ead7c4fd99acda4b02c10fbc20cc831fd949e10e8e6e7c8c9e30b0b46a23
f3b7922e44bcd67185de9518f822d78a8577ccb0ad95aca516b0ef3c12711f5b
04dfab9a79f6c39c1b67cd15c1a9f319bcb299ccddac2b6d3d778d695a3bcc3f
16349832bcd9ac9ce87e758cdc688e01f24f2cf68c7915a830a9cb992fa97105
25e0848c239ca3c97dcee9f8d4f83995a57901ab750b8ee147c47f6d6d38c4e1
80bfdccb21b1ed836b3a4e83235a91d9c95a633fa79a287ed5074a5e4212b602
31963258eab7753a344bb67bc05240e4186f5cdfb976b0112553e0ddc30f2a25
f59aaa4b133133857c038fed2f0b72ead40df0db9b8254b08cf059d2ce06899b
c800403bfb5bab3dc6858c2f2dec06be20fe30db135560e3607575cd1c3db15e
b9e241f357a5efa8d0a32dc23fee8590d7e9a8fff0f6637fd3127715e927f0aa
9b154226ff704b060afcc659a177501db0f08135c6ebab215ea0aaec7a3c4897
396c1861cfe5cbe93ca43e66e47af013863381b3a1f6dbe349db4bcd29f5a28e
1f8168c2acee2baf6f60af1825ae31d69dbc2b7cb210be2338914c8da5a768e8
2fb1faa4accb64770b101fe1d8cea43dc4a4b0afe8539f8f43909ca96c5083ac
7829f05276216cdb5c077af6aab7d5b24160a0a8fd5b68746beb5cbb23d2622d
96978b9b166d175db881350937e70540a0c849671df9a01da05972226b856ff4
94c125445b9cda14cae7bd197e1a0d3fe102aa056cb46dacf8eeed02b71494cb
039b4d62b02fddde80034ae58feafeaf4ca13b1dcaaf71a229e470e603cadefa
ff5cdc94fafe9d4d791ae385fd59851086a34c14964fcfda28e202a913c9a2ac
14ab7717005f4b87352e78f48b2bd746bcf68f17032393c97214828bd816208d
f89658375eaa44afecbd5ef097330bfab8065cd518658b707b63260db3ffe2a4
5dbb37cf20b8e0feaf5075f426fc1773e90da52e517d0ec4504efbe496d283c5
2244992a1ff15619d6fbf0b03f7a3bcc042b1c11c6308064548574b9c43ed62b
89418e91d414bf3a7163e8eacdbcdda1f9eb6327ab85d31645cba392be1b6290
b77eb3811701101c7f6e5adaa748675fb58e05beb1dfb4e0eacd0790d86211b2
2ee62c1b8d2c0d8088d51296b92d97c2393a7e224404e13a5109f81c8d385bb5
f880e405a286ed72717fe6b7775a9064f3fe3f30513eb9a085c0e2a919a06f6b
cc2e19f589e2e4abb0d753f3d4805c6eb88b83c06d08410e880c6d7ef2216323
97f8614119b1a5ad8acf1051b46125ad52418b6df5a0468f1c0ac23cfecec1b8
a26014e1059d6410a1af9afa7a1309a4ee5348fa180796bb3951f7044bdf1326
8793a33281a711b4691bd7e54cd64b03150c87fd8d1760e1bcbaafe3b4390032
d23319818439074c0bbb6521a363466f442536d0afa3b5d1f25df292e108675a
23bdd78913cd19c5d09528a14221fdd15bb1356d350cb0bc100d181a46849b40
d05fd1bd45e86b1b05887b1689bd6c852072c99c8fa41ef87d401fd800b8c4fb
1ca8f5afb13058c21cd9a6b1245ea8a66ced2c37762e1c7ca3a49f514595bf29
f52684ce2299754cd3165e60ee4f3f76b7be9bc04afec0eac3460931323001eb
53c6f0039a36bac7d0f5d10d24f108e19f98a51393ee5bc9a67cb9935c058d63
81c05b4b1da2b8e36c7c4d8ede1514934ac722d5ba101d971da522f02a6707ea
521e9904915484cb4edf9355bc5763ac846b18916e32af551953062b3bb093db
161a61fbe6eeb0cd611e728a2e1f4aff4b8339a1cf4b744ac1ceba697cbea063
13fe08ff66c17f4fcd2674205fc306cab3c01b42f716633366a6c44ec43f2b67
90750cc75585e03e5e226bbd3ca79a42fe14fe69b6c4defe167c6d12556da93b
1662b8c5b17000930933def5e004c260884560647e5c0c26779042d9102a0cef
a96395fe153a83b402234e454eb4736b54285552715a287298423df122bec8ec
dcc39b83279d65f79eaa4f3f86519d72c6e6c628dd54a2cb56830807e9ee67c6
deeffc2c43dff791b1818620444be078479d803b06c9cdc50c21d4f84fd87375
15ed7963c5eb764d12a868d5bffbb5bd3632d06adc6980c1ff8e168ca79eb131
d022b0d74d65a86746c128747713f70019e844ba5412a4a89d087dd5293d7e96
94ae8c13a42c3ecb0ecc030f00394f97fc1ee329380f52ff4d4bd2126b33ebab
69d40871a148b253175457d1c167ee1dda6dbb911485b6ac36c13c482fb4f096
223cd32674592935f6c26e2a768b9aedfdbbe318bf58ff5124b738395d51f1fc
e898a276a85c48383f1584c849af378a28fc7aca5ae60770b741dc377160124b
f7d8d491a0e91729610ee3ac5963571f516aa7e94bdbf6a71c48278f6d618a14
4489227a57239392b803f7be12d048a14ffd7cafb3505aee6fbcb8789b09a209
be28aa9ccfad7f6ecb25441f0f6af6eb21242e276322e9d9f488c15215f94296
3f953bfe384aff38d921b784961033baabc5fd78a95b7ae05fe47113b1cee110
2c6ccfa585a11a1d3c88f05b5c552e2195560e4abc1b3f54f264adafeace55d0
'''.split())

# Generic rules. They run on every text view of a file (UTF-8, and UTF-16 when the bytes are not
# plain UTF-8), after NFKC normalization.
PATTERNS = [
    ('private-key', re.compile(r'-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----')),
    ('github-token', re.compile(r'(?:gh[pousr]_[A-Za-z0-9]{30,255}|github_pat_[A-Za-z0-9_]{50,255})')),
    ('huggingface-token', re.compile(r'(?<![A-Za-z0-9])hf_[A-Za-z0-9]{30,}')),
    ('aws-access-key', re.compile(r'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b')),
    ('api-secret', re.compile(r'\bsk-(?:proj-|ant-[a-z0-9]{2,8}-)?[A-Za-z0-9_-]{32,255}')),
    ('slack-token', re.compile(r'\bxox[abposr]-[A-Za-z0-9-]{10,}')),
    ('google-api-key', re.compile(r'\bAIza[0-9A-Za-z_-]{35}')),
    ('stripe-live-key', re.compile(r'\b[rs]k_live_[0-9A-Za-z]{16,}')),
    ('assigned-secret', re.compile(r'(?i)\b(?:hf_token|api[_-]?key|secret[_-]?key|access[_-]?token|auth[_-]?token|password)\b'
                                   r'\s*[:=]\s*["\']?[A-Za-z0-9_\-]{24,}')),
    # Personal folders under the home directory (Desktop, Documents, Downloads, …), written with
    # a tilde or $HOME; documentation names the folder in words instead.
    ('personal-folder-path', re.compile(r'(?:~|\$HOME|\$\{HOME\})/(?:Desktop|Documents|Downloads|Pictures|Movies|Music)(?![A-Za-z])')),
    # Character-style persona descriptions: an age together with a school identity.
    ('persona-description', re.compile(
        r'(?:十几|[一二两三四五六七八九十]{1,3}|\d{1,2})\s*[岁歲歳][^。\n]{0,12}?(?:高中|初中|中学|中學|高校|国中|國中)[^。\n]{0,6}?(?:男生|女生|男孩|女孩|学生|學生|生)'
        r'|(?:高中|初中|中学|中學|高校|国中|國中)(?:男生|女生|男孩|女孩|学生|學生|生)[^。\n]{0,12}?(?:十几|[一二两三四五六七八九十]{1,3}|\d{1,2})\s*[岁歲歳]'
        r'|(?i:\b(?:\d{1,2}|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen)[- ]years?[- ]old\b[^.\n]{0,40}?\b(?:high|middle|secondary)[- ]?school'
        r'|\b(?:high|middle|secondary)[- ]?school(?:er)?\s+(?:boy|girl|student|kid)\b[^.\n]{0,40}?\b\d{1,2}[- ]years?[- ]old\b'
        r'|\bteen(?:age)?\s+(?:high[- ]?school\s+)?(?:boy|girl)\b)')),
]
# /Users/<name> or /home/<name>, with or without a trailing slash. Allowed: /Users/Shared and
# documentation placeholders (/Users/<name>, /Users/$USER, and the words in PLACEHOLDER_USERS).
HOME_PATH = re.compile(r'(?<![A-Za-z0-9_.-])/(?:Users|home)/([A-Za-z0-9][A-Za-z0-9._-]{0,63})')
PLACEHOLDER_USERS = {'shared', 'you', 'me', 'name', 'user', 'username', 'yourname', 'your-name', 'example'}
# E-mail addresses. Allowed: GitHub noreply addresses, and an obvious placeholder: one of
# PLACEHOLDER_MAILBOXES at a reserved example domain (RFC 2606: example.com/.net/.org, *.example,
# *.test, *.invalid, *.localhost). image@2x.png-style file names are not addresses.
EMAIL = re.compile(r'(?<![A-Za-z0-9._%+-])([A-Za-z0-9._%+-]{1,64})@((?:[A-Za-z0-9-]{1,63}\.)+[A-Za-z]{2,24})(?![A-Za-z0-9-])')
PLACEHOLDER_MAILBOXES = {'you', 'your-name', 'yourname', 'your.name', 'name', 'user', 'username', 'email', 'noreply', 'no-reply'}
FILE_SUFFIX_TLDS = {'png', 'jpg', 'jpeg', 'gif', 'svg', 'pdf', 'icns', 'webp', 'heic', 'tiff'}
MAX_SOURCE_FILE = 8 * 1024 * 1024
MAX_RELEASE_FILE = 64 * 1024 * 1024
MAX_ARCHIVE_TOTAL = 256 * 1024 * 1024
DEFAULT_ACCEPTED_HISTORY = Path(__file__).resolve().parent / 'audit-history-accepted.json'


def allowed_email(local: str, domain: str) -> bool:
    domain = domain.lower()
    if domain == 'noreply.github.com' or domain.endswith('.noreply.github.com'):
        return True
    if domain.rsplit('.', 1)[-1] in FILE_SUFFIX_TLDS:
        return True
    reserved = (domain in {'example.com', 'example.net', 'example.org'}
                or domain.endswith(('.example', '.test', '.invalid', '.localhost')))
    return reserved and local.lower() in PLACEHOLDER_MAILBOXES


# Look-alike letters (Cyrillic, Greek and a few Latin variants) folded to the Latin letter they imitate.
# Mapped before case folding, so an upper-case look-alike maps to the upper-case Latin letter.
HOMOGLYPHS = str.maketrans(
    # Cyrillic capitals, Cyrillic small letters, Greek capitals, Greek small letters, Latin variants
    'АВЕКМНОРСТХУЅІЈԚԜҮӀ'
    'аеорсухіјѕԁӏԛԝһүьк'
    'ΑΒΕΖΗΙΚΜΝΟΡΤΥΧ'
    'αορνυικχγηϲϳε'
    'ıɡɑ',
    'ABEKMHOPCTXYSIJQWYl'
    'aeopcyxijsdlqwhybk'
    'ABEZHIKMNOPTYX'
    'aopvuikxyncje'
    'iga')
# Common traditional Chinese forms -> simplified (pairs). Used when PyICU is not installed; a
# private name written in traditional characters must still match its simplified spelling.
TRADITIONAL_PAIRS = '''
萬万 與与 專专 業业 叢丛 東东 絲丝 兩两 嚴严 喪丧 個个 豐丰 臨临 為为 麗丽 舉举 義义 烏乌 樂乐 喬乔
習习 鄉乡 書书 買买 亂乱 爭争 虧亏 雲云 亞亚 產产 親亲 億亿 僅仅 從从 倉仓 儀仪 們们 價价 眾众 優优
會会 傘伞 偉伟 傳传 傷伤 倫伦 偽伪 體体 傭佣 俠侠 側侧 債债 傾倾 償偿 儲储 兒儿 黨党 蘭兰 關关 興兴
養养 獸兽 岡冈 冊册 寫写 軍军 農农 馮冯 衝冲 決决 況况 凍冻 淨净 涼凉 減减 幾几 鳳凤 憑凭 凱凯 擊击
劃划 劉刘 則则 剛刚 創创 刪删 別别 劑剂 劍剑 劇剧 勸劝 辦办 務务 動动 勵励 勁劲 勞劳 勢势 勳勋 區区
醫医 華华 協协 單单 賣卖 盧卢 衛卫 卻却 廠厂 廳厅 歷历 曆历 厲厉 壓压 厭厌 縣县 參参 雙双 發发 變变
敘叙 疊叠 葉叶 號号 嘆叹 嚇吓 呂吕 嗎吗 啟启 吳吴 員员 嗚呜 響响 啞哑 喚唤 問问 嘯啸 噴喷 團团 園园
圍围 圖图 圓圆 聖圣 場场 壞坏 塊块 堅坚 壇坛 墳坟 墜坠 壘垒 墊垫 塵尘 壯壮 聲声 殼壳 壺壶 處处 備备
復复 夠够 頭头 誇夸 奪夺 奮奋 獎奖 婦妇 媽妈 嬌娇 孫孙 學学 寶宝 實实 寵宠 審审 憲宪 宮宫 寬宽 賓宾
寢寝 對对 尋寻 導导 將将 爾尔 嘗尝 層层 屬属 歲岁 島岛 峽峡 嶺岭 巖岩 幣币 師师 帳帐 帶带 幫帮 幹干
廣广 莊庄 慶庆 廬庐 庫库 應应 廟庙 廢废 開开 異异 棄弃 張张 彌弥 彎弯 彙汇 歸归 當当 錄录 徹彻 徑径
後后 憶忆 懷怀 態态 憂忧 憐怜 總总 戀恋 惡恶 惱恼 悅悦 驚惊 慣惯 懶懒 憤愤 願愿 戲戏 戰战 戶户 撲扑
執执 擴扩 掃扫 揚扬 擾扰 撫抚 拋抛 搶抢 護护 報报 擔担 擬拟 攏拢 擁拥 攔拦 撥拨 擇择 掛挂 撈捞 損损
撿捡 換换 據据 擺摆 攜携 搖摇 攝摄 擠挤 擋挡 敵敌 數数 齋斋 斷断 無无 舊旧 時时 曠旷 晝昼 顯显 晉晋
曉晓 暈晕 暫暂 術术 機机 殺杀 雜杂 權权 條条 來来 楊杨 極极 構构 樞枢 標标 棟栋 欄栏 樹树 樣样 橋桥
檢检 樓楼 歡欢 歐欧 殘残 毀毁 氣气 漢汉 湯汤 溝沟 沒没 淪沦 滄沧 滬沪 淚泪 潑泼 澤泽 灑洒 濃浓 濁浊
測测 濟济 渾浑 濤涛 潤润 漲涨 淵渊 漁渔 漸渐 滲渗 溫温 灣湾 濕湿 滿满 濾滤 濫滥 瀏浏 灘滩 滯滞 潛潜
瀾澜 滅灭 燈灯 靈灵 災灾 爐炉 點点 煉炼 爛烂 燒烧 煩烦 熱热 營营 燦灿 燭烛 爺爷 牆墙 犧牺 狀状 獨独
狹狭 獄狱 獅狮 貓猫 獵猎 現现 環环 瑪玛 瓊琼 畫画 暢畅 療疗 瘋疯 癢痒 盞盏 監监 盤盘 盜盗 礙碍 碼码
確确 礦矿 禮礼 禍祸 離离 種种 積积 稱称 穩稳 窮穷 竊窃 競竞 筆笔 節节 範范 築筑 簡简 籃篮 籌筹 簽签
類类 糧粮 糾纠 紅红 紀纪 約约 級级 紡纺 紋纹 納纳 純纯 紙纸 線线 練练 組组 細细 終终 經经 結结 給给
絡络 統统 絕绝 繼继 續续 綠绿 維维 綱纲 網网 緊紧 緒绪 編编 緣缘 縮缩 織织 繞绕 繪绘 罰罚 羅罗 聯联
聰聪 職职 聽听 肅肃 腦脑 膽胆 臉脸 腳脚 膚肤 艱艰 藝艺 蘇苏 蘋苹 莖茎 薦荐 葦苇 蔥葱 藥药 蓋盖 蟲虫
蝦虾 補补 襯衬 裝装 製制 見见 規规 視视 覺觉 覽览 觀观 訂订 計计 討讨 訓训 記记 講讲 許许 論论 設设
訪访 證证 評评 識识 詩诗 試试 話话 該该 詳详 語语 誤误 說说 請请 諸诸 讀读 課课 誰谁 調调 談谈 謝谢
謠谣 謎谜 讓让 議议 譯译 貝贝 負负 財财 貢贡 貧贫 貨货 販贩 貪贪 責责 貴贵 費费 貼贴 貿贸 賀贺 資资
賊贼 賠赔 賞赏 賬账 質质 購购 贈赠 贊赞 趕赶 趙赵 躍跃 蹤踪 車车 軌轨 軟软 轉转 輪轮 輕轻 較较 載载
輔辅 輛辆 輸输 轟轰 辭辞 邊边 遼辽 達达 遷迁 過过 運运 還还 這这 進进 遠远 連连 遲迟 適适 選选 遺遗
郵邮 鄰邻 鄭郑 醜丑 釋释 裡里 鑒鉴 針针 釣钓 鈴铃 鉛铅 銀银 銅铜 銷销 鋪铺 鋒锋 鋼钢 錢钱 錯错 鍋锅
鍵键 鍾钟 鐘钟 鐵铁 鑰钥 長长 門门 閃闪 閉闭 閒闲 間间 閱阅 闊阔 闖闯 隊队 陽阳 陰阴 陣阵 階阶 際际
陸陆 陳陈 隨随 險险 隱隐 隻只 雞鸡 難难 雖虽 電电 霧雾 靜静 韓韩 頁页 頂顶 項项 順顺 須须 預预 領领
頻频 題题 額额 顏颜 顧顾 風风 飛飞 飯饭 飲饮 飽饱 餓饿 館馆 饅馒 馬马 駕驾 駐驻 騎骑 騙骗 驗验 驅驱
髮发 鬥斗 鬧闹 魚鱼 鮮鲜 鳥鸟 鳴鸣 鴨鸭 鵝鹅 鷹鹰 麥麦 黃黄 齊齐 齒齿 龍龙 龜龟 蓮莲 藍蓝 碩硕 壽寿
畢毕 淺浅 盡尽 稅税 鎮镇 鏡镜 麼么 傑杰 檔档 慮虑 輯辑 誌志 夢梦 鄧邓 鏈链 礎础 齡龄 嶼屿 濱滨 陝陕
臺台 硯砚 灤滦 瀋沈 蕭萧 葷荤 薩萨 藹蔼 蘆芦 蘊蕴 藏藏 蔣蒋 蕩荡 獲获 穫获 憫悯 懲惩 戔戋 鐳镭 鑽钻 鑄铸
'''.split()
TRADITIONAL = {ord(pair[0]): pair[1] for pair in TRADITIONAL_PAIRS if len(pair) == 2 and pair[0] != pair[1]}
try:                                     # PyICU, when installed, covers every traditional form
    import icu  # type: ignore
    _HANT_HANS = icu.Transliterator.createInstance('Hant-Hans')
except Exception:                        # the standard library has no ICU; use the table above
    _HANT_HANS = None
_FOLD_TABLE: dict[int, object] | None = None


def _fold_table() -> dict[int, object]:
    """Combining marks (M*, variation selectors included) and format characters (Cf: zero-width
    joiners and spaces, bidi controls, BOM, tags) are dropped; look-alikes and traditional forms mapped."""
    global _FOLD_TABLE
    if _FOLD_TABLE is None:
        table: dict[int, object] = {}
        for block in (range(0x20000), range(0xE0000, 0xE1000)):
            for cp in block:
                category = unicodedata.category(chr(cp))
                if category[0] == 'M' or category == 'Cf':
                    table[cp] = None
        table.update(HOMOGLYPHS)
        table.update(TRADITIONAL)
        _FOLD_TABLE = table
    return _FOLD_TABLE


def fold(text: str) -> str:
    """The form private terms are compared in: NFKD, marks/format characters dropped, look-alike
    letters and traditional forms mapped, case-folded, NFKC."""
    text = unicodedata.normalize('NFKD', text).translate(_fold_table())
    if _HANT_HANS is not None:
        text = _HANT_HANS.transliterate(text)
    return unicodedata.normalize('NFKC', text.casefold())


def squash(text: str) -> str:
    """Drops whitespace, punctuation, symbols, marks and control/format characters."""
    return ''.join(c for c in text if unicodedata.category(c)[0] not in 'ZPSCM')


def normalize(text: str) -> str:
    return fold(text)


# Audio and audio/video containers. Signatures of 6+ distinctive bytes are searched anywhere in the
# file (a copy hidden behind a few prefix bytes, or inside another container, is still found); short
# ones only at the start.
AUDIO_ANYWHERE = re.compile(
    rb'(?:RIFF|RF64|BW64).{4}(?:WAVE|AVI )|FORM.{4}AIF[FC]|fLaC\x00\x00\x00\x22|OggS\x00[\x00-\x07]'
    rb'|caff\x00\x01\x00\x00|ftyp(?:M4A |M4B |M4P |M4V |mp4[12]|isom|iso[2-9]|avc1|qt  |3gp[0-9]|3g2[a-c]|dash|f4[av] |MSNV)'
    rb'|\.snd\x00\x00\x00[\x18-\xff]|ID3[\x02-\x04]\x00|#!AMR|MAC \x96\x0f|\x30\x26\xb2\x75\x8e\x66\xcf\x11', re.S)
AUDIO_AT_START = (b'\x1a\x45\xdf\xa3', b'wvpk', b'dns.')


def audio_signature(data: bytes) -> str | None:
    """A short label for the audio/video container that `data` holds (or embeds), or None."""
    match = AUDIO_ANYWHERE.search(data)
    if match:
        return match.group()[:4].decode('latin-1').strip() or 'audio'
    if data.startswith(AUDIO_AT_START):
        return 'audio'
    if len(data) >= 4 and data[0] == 0xFF and data[1] & 0xE0 == 0xE0:
        version, layer = (data[1] >> 3) & 3, (data[1] >> 1) & 3
        if layer == 0 and data[1] & 0xF6 == 0xF0:                  # ADTS AAC
            return 'adts'
        if version != 1 and layer != 0 and data[2] >> 4 != 15 and (data[2] >> 2) & 3 != 3:
            return 'mpeg'
    return None


def archive_kind(data: bytes) -> str | None:
    if data[:4] in (b'PK\x03\x04', b'PK\x05\x06', b'PK\x07\x08'):
        return 'zip'
    if data[:3] == b'\x1f\x8b\x08':
        return 'gzip'
    if re.match(rb'BZh[1-9](?:1AY&SY|\x17rE8P\x90)', data[:10]):
        return 'bzip2'
    if data[:6] == b'\xfd7zXZ\x00':
        return 'xz'
    if data[257:262] == b'ustar':
        return 'tar'
    for magic, kind in ((b'7z\xbc\xaf\x27\x1c', '7z'), (b'Rar!\x1a\x07', 'rar'), (b'\x28\xb5\x2f\xfd', 'zstd'),
                        (b'xar!', 'xar'), (b'AA01', 'apple-archive'), (b'YAA1', 'apple-archive'),
                        (b'\x04\x22\x4d\x18', 'lz4'), (b'\x1f\x9d', 'compress'), (b'070707', 'cpio'),
                        (b'070701', 'cpio'), (b'070702', 'cpio')):
        if data.startswith(magic):
            return kind
    if len(data) >= 512 and data[-512:-508] == b'koly':
        return 'dmg'
    return None


def zip_entry_name(info: zipfile.ZipInfo) -> str:
    """ditto (and other macOS tools) store UTF-8 names without the UTF-8 flag (0x800), which Python
    then reads as cp437; turn those back into the real name."""
    try:
        recovered = info.filename.encode('cp437').decode('utf-8')
    except UnicodeError:
        return info.filename
    return recovered


def legacy_cjk_views(data: bytes) -> list[str]:
    """GB18030 and Big5 readings of text that is not UTF-8 (strict decoding, so binaries never qualify)."""
    if b'\x00' in data or is_plain_text(data):
        return []
    views = []
    for codec in ('gb18030', 'big5'):
        try:
            views.append(data.decode(codec))
        except UnicodeDecodeError:
            pass
    return views


B64_RUN = re.compile(r'[A-Za-z0-9+/_-]{12,}')
B64_WRAP = re.compile(r'(?<=[A-Za-z0-9+/_=-])[ \t]*\r?\n[ \t]*(?=[A-Za-z0-9+/_-])')
MAX_BASE64_SCAN = 32 * 1024 * 1024


def base64_payloads(text: str):
    """Decodings of every Base64 run of 12+ characters (standard or URL-safe alphabet, line wraps
    joined), at all four alignments, so a payload that starts inside a longer word still decodes
    correctly at one of them. The garbage the other alignments give is only checked for private
    terms with the binary-data rules, where chance matches are negligible."""
    budget = MAX_BASE64_SCAN
    for match in B64_RUN.finditer(B64_WRAP.sub('', text)):
        run = match.group().replace('-', '+').replace('_', '/')
        for offset in range(4):
            part = run[offset:]
            part = part[:len(part) - (len(part) % 4 == 1)]       # one leftover character holds no byte
            budget -= len(part)
            if budget < 0:
                return
            yield base64.b64decode(part + '=' * (-len(part) % 4))


def png_texts(data: bytes, limit: int = 8 * 1024 * 1024) -> list[str]:
    """Text of the tEXt, zTXt and iTXt chunks of a PNG (compressed ones inflated, capped at `limit`)."""
    texts, pos = [], 8
    def inflate(raw: bytes) -> bytes:
        return zlib.decompressobj().decompress(raw, limit)
    while pos + 8 <= len(data):
        length = int.from_bytes(data[pos:pos + 4], 'big')
        kind, body = data[pos + 4:pos + 8], data[pos + 8:pos + 8 + length]
        pos += 12 + length
        try:
            if kind == b'tEXt':
                texts.append(body.replace(b'\x00', b'\n').decode('utf-8', errors='replace'))
            elif kind == b'zTXt':
                key, _, rest = body.partition(b'\x00')
                texts.append((key + b'\n' + inflate(rest[1:])).decode('utf-8', errors='replace'))
            elif kind == b'iTXt':
                key, _, rest = body.partition(b'\x00')
                compressed, lang_and_text = rest[0], rest[2:]
                lang, _, rest = lang_and_text.partition(b'\x00')
                translated, _, text = rest.partition(b'\x00')
                text = inflate(text) if compressed else text
                texts.append(b'\n'.join((key, lang, translated, text)).decode('utf-8', errors='replace'))
        except (zlib.error, IndexError):
            texts.append('')
        if kind == b'IEND':
            break
    return texts


def load_deny_terms(values: list[str], files: list[Path], environ: dict[str, str]) -> list[tuple[str, str | None]]:
    """(plain, squashed-or-None). Short ASCII terms match only in their plain form, so a term such
    as 'ab1' cannot match random letters with punctuation between them."""
    raw = list(values)
    for path in files:
        raw += path.read_text(encoding='utf-8').splitlines()
    raw += environ.get('RELEASE_DENY_TERMS', '').splitlines()
    terms = []
    for line in raw:
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        plain = normalize(line)
        squashed = squash(plain)
        if len(squashed) < 2:
            continue
        use_squash = not squashed.isascii() or len(squashed) >= 6
        item = (plain, squashed if use_squash else None)
        if item not in terms:
            terms.append(item)
    return terms


MEDIA_MAGIC = (b'RIFF', b'\x89PNG', b'icns', b'\xff\xd8\xff', b'GIF8', b'FORM', b'%PDF')


def is_plain_text(data: bytes) -> bool:
    try:
        data.decode('utf-8')
    except UnicodeDecodeError:
        return False
    return b'\x00' not in data


def text_views(data: bytes) -> list[str]:
    """UTF-8 always; UTF-16 (both byte orders) when the bytes are not plain UTF-8 text."""
    views = [data.decode('utf-8', errors='replace')]
    if not is_plain_text(data):
        body = data[2:] if data[:2] in (b'\xff\xfe', b'\xfe\xff') else data
        for codec in ('utf-16-le', 'utf-16-be'):
            views.append(body[:len(body) // 2 * 2].decode(codec, errors='replace'))
    return [unicodedata.normalize('NFKC', v) for v in views]


MAX_NESTED_DEPTH = 3                 # archive inside archive inside archive; deeper is reported, not opened
MAX_NESTED_MEMBERS = 20000
# Rules about a path rather than a blob's bytes. In history mode an accepted entry waives them only
# for the paths it lists, so accepting a blob never lets the same bytes appear under a forbidden name.
PATH_RULES = {'private-term-in-path', 'unsafe-path', 'excluded-directory', 'excluded-artifact',
              'local-metadata-or-environment', 'nested-archive-name'}


class Audit:
    def __init__(self, mode: str, deny_terms: list[tuple[str, str | None]]):
        self.mode = mode
        self.deny = deny_terms
        self.findings: list[dict[str, str]] = []
        self.manifest: list[dict[str, object]] = []
        self.voice_files: dict[str, str] = {}       # path -> sha256 of an allowed-audio file
        self.voice_json: dict[str, bytes] = {}      # path -> companion_voice.json data
        self.plists: dict[str, bytes] = {}
        self.shown_paths: dict[str, str] = {}       # real path -> what reports show
        self.unpacked_bytes = 0
        self.withheld = 0

    def shown(self, name: str) -> str:
        """The path as reports show it: a path that contains a private term is never printed, by any
        rule or in the manifest; it becomes '<path withheld #N>' (the same N for the same path)."""
        if name not in self.shown_paths:
            if self.private_term_in(name):
                self.withheld += 1
                self.shown_paths[name] = f'<path withheld #{self.withheld}>'
            else:
                self.shown_paths[name] = name
        return self.shown_paths[name]

    def flag(self, name: str, rule: str, **extra: str) -> None:
        item = {'path': self.shown(name), 'rule': rule, **extra}
        if item not in self.findings:
            self.findings.append(item)

    def private_term_in(self, text: str, binary: bool = False) -> bool:
        """In binary data (executables, media) separate strings run together once punctuation and
        NULs are dropped, and short ASCII words occur by chance; there only the plain form of
        non-ASCII terms and of ASCII terms of 5+ characters is used. Source text gets every form."""
        if not self.deny:
            return False
        folded = fold(text)
        squashed = None
        for plain, squashed_term in self.deny:
            if binary and plain.isascii() and len(plain) < 5:
                continue
            if plain in folded:
                return True
            if squashed_term and not (binary and squashed_term.isascii()):
                if squashed is None:
                    squashed = squash(folded)
                if squashed_term in squashed:
                    return True
        return False

    @staticmethod
    def allowed_audio(name: str) -> bool:
        return '!/' not in name and any(name == a or name.endswith('/' + a) for a in ALLOWED_AUDIO)

    def name(self, name: str, history: bool = False, nested: bool = False) -> bool:
        path = PurePosixPath(name)
        parts = path.parts
        if self.private_term_in(name):
            self.flag(name, 'private-term-in-path')     # shown() withholds the path itself
        if path.is_absolute() or '..' in parts or '\\' in name or '!//' in name:
            self.flag(name, 'unsafe-path')
            return False
        if any(p in FORBIDDEN_COMPONENTS for p in parts):
            self.flag(name, 'excluded-directory')
        if (path.suffix.lower() in FORBIDDEN_SUFFIXES and not self.allowed_audio(name)) or path.name in FORBIDDEN_ASSETS:
            self.flag(name, 'excluded-artifact')
        if path.suffix.lower() in ARCHIVE_SUFFIXES:     # the release must not carry archives of its own
            self.flag(name, 'nested-archive-name')
        if path.name == '.DS_Store' or path.name == '.env' or path.name.startswith('.env.'):
            self.flag(name, 'local-metadata-or-environment')
        if self.mode == 'source' and not history and not nested:
            if len(parts) == 1 and parts[0] not in SOURCE_ROOT_FILES:
                self.flag(name, 'unlisted-root-file')
            if len(parts) > 1 and parts[0] not in SOURCE_TOP:
                self.flag(name, 'unlisted-source-directory')
            if path.suffix.lower() in {'.zip', '.dmg', '.gz', '.dylib', '.so'} or any(p.endswith('.app') for p in parts):
                self.flag(name, 'binary-or-archive-in-source')
        return True

    def text_rules(self, name: str, text: str, binary: bool, media: bool) -> None:
        if self.private_term_in(text, binary=binary):
            self.flag(name, 'private-term')
        if media:
            return
        for label, pattern in PATTERNS:
            if pattern.search(text):
                self.flag(name, label)
        for match in HOME_PATH.finditer(text):
            if match.group(1).lower() not in PLACEHOLDER_USERS:
                self.flag(name, 'private-home-path')
                break
        for match in EMAIL.finditer(text):
            if not allowed_email(match.group(1), match.group(2)):
                self.flag(name, 'email-address')
                break
        for match in re.finditer(r'CFBundleIdentifier</key>\s*<string>([^<]*)</string>', text):
            if match.group(1) != PUBLIC_BUNDLE_ID:
                self.flag(name, 'unexpected-bundle-identifier')

    def content(self, name: str, data: bytes, depth: int = 0) -> None:
        digest = hashlib.sha256(data).hexdigest()
        self.manifest.append({'path': self.shown(name), 'bytes': len(data), 'sha256': digest})
        if digest in RETIRED_VOICE_SHA256:
            self.flag(name, 'retired-voice')
        if digest in PRIVATE_ASSET_SHA256:
            self.flag(name, 'private-asset')
        pinned = depth == 0 and self.allowed_audio(name)
        if pinned:
            self.voice_files[name] = digest
        if depth == 0 and name.endswith('companion_voice.json'):
            self.voice_json[name] = data
        if depth == 0 and (name == 'Contents/Info.plist' or re.fullmatch(r'(?:[^/]+/)?[^/]+\.app/Contents/Info\.plist', name)):
            self.plists[name] = data
        binary = not is_plain_text(data)
        audio = audio_signature(data) if binary else None
        if audio and not pinned:
            # Any audio other than the pinned voice, however it is named, encoded or edited.
            self.flag(name, 'audio-content')
        # Audio and images: random sample bytes would only produce chance matches for the text
        # rules, so media gets the private-term check alone.
        media = bool(audio) or data.startswith(MEDIA_MAGIC)
        for text in text_views(data):
            self.text_rules(name, text, binary, media)
        for text in legacy_cjk_views(data):
            if self.private_term_in(text):
                self.flag(name, 'private-term')
        if not binary and self.deny:
            for payload in base64_payloads(data.decode('utf-8')):
                if len(payload) >= 4 and any(self.private_term_in(v, binary=not is_plain_text(payload))
                                             for v in text_views(payload)):
                    self.flag(name, 'private-term', encoding='base64')
                    break
        if data.startswith(b'\x89PNG\r\n\x1a\n'):
            for text in png_texts(data):
                self.text_rules(name, text, binary=False, media=False)
        kind = archive_kind(data)
        if kind:
            self.flag(name, 'nested-archive', kind=kind)
            self.unpack(name, kind, data, depth + 1)

    def unpack(self, name: str, kind: str, data: bytes, depth: int) -> None:
        """Reads an archive found inside the release in memory and audits every member as
        '<archive>!/<member>'. Member size, member count, total unpacked bytes and depth are capped,
        and members are read one at a time, so a compression bomb cannot exhaust memory."""
        if depth > MAX_NESTED_DEPTH:
            self.flag(name, 'archive-not-scanned', reason='nested too deep')
            return
        if kind not in ('zip', 'tar', 'gzip', 'bzip2', 'xz'):
            self.flag(name, 'archive-not-scanned', reason='format not readable here')
            return

        def limit() -> int:
            return max(0, min(MAX_RELEASE_FILE, MAX_ARCHIVE_TOTAL - self.unpacked_bytes))

        def members():
            if kind == 'zip':
                with zipfile.ZipFile(io.BytesIO(data)) as archive:
                    for info in archive.infolist():
                        if info.is_dir():
                            continue
                        if info.flag_bits & 1:
                            self.flag(name + '!/' + zip_entry_name(info), 'encrypted-archive-entry')
                            continue
                        with archive.open(info) as stream:
                            yield zip_entry_name(info), stream.read(limit() + 1)
            elif kind == 'tar':
                with tarfile.open(fileobj=io.BytesIO(data), mode='r:') as archive:
                    for info in archive:
                        if info.issym() or info.islnk():
                            if info.linkname.startswith('/') or '..' in PurePosixPath(info.linkname).parts:
                                self.flag(name + '!/' + info.name, 'unsafe-archive-symlink')
                        elif info.isfile():
                            stream = archive.extractfile(info)
                            yield info.name, stream.read(limit() + 1) if stream else b''
            else:
                if kind == 'gzip':
                    with gzip.GzipFile(fileobj=io.BytesIO(data)) as stream:
                        inner = stream.read(limit() + 1)
                elif kind == 'bzip2':
                    inner = bz2.BZ2Decompressor().decompress(data, max_length=limit() + 1)
                else:
                    inner = lzma.LZMADecompressor().decompress(data, max_length=limit() + 1)
                stem = PurePosixPath(name).name
                for suffix, replacement in (('.tgz', '.tar'), ('.tbz2', '.tar'), ('.tbz', '.tar'), ('.txz', '.tar'),
                                            ('.gz', ''), ('.bz2', ''), ('.xz', '')):
                    if stem.lower().endswith(suffix):
                        stem = stem[:-len(suffix)] + replacement
                        break
                yield stem or 'content', inner

        count = 0
        try:
            for member, payload in members():
                count += 1
                if count > MAX_NESTED_MEMBERS:
                    self.flag(name, 'archive-not-scanned', reason='too many members')
                    return
                full = name + '!/' + member
                if not self.name(full, nested=True):
                    continue
                if len(payload) > limit():
                    self.flag(full, 'unexpected-large-file')
                    self.flag(name, 'archive-not-scanned', reason='member or total size over the limit')
                    return
                self.unpacked_bytes += len(payload)
                self.content(full, payload, depth)
        except Exception:
            self.flag(name, 'archive-not-scanned', reason='unreadable or corrupt')

    def finish(self, history: bool = False) -> None:
        """Checks that need the whole tree: the pinned voice and the bundle identifier."""
        for name, digest in sorted(self.voice_files.items()):
            if digest != COMPANION_VOICE_SHA256:
                self.flag(name, 'companion-voice-not-pinned')
            if history:
                continue  # one blob at a time: its JSON sidecar is a different blob
            sidecar = name[:-len('.wav')] + '.json'
            try:
                recorded = json.loads(self.voice_json[sidecar]).get('sha256')
            except (KeyError, ValueError, AttributeError):
                recorded = None
            if recorded != digest:
                self.flag(sidecar, 'companion-voice-json-mismatch')
        for name, data in sorted(self.voice_json.items()):
            try:
                recorded = json.loads(data).get('sha256')
            except (ValueError, AttributeError):
                recorded = None
            if recorded != COMPANION_VOICE_SHA256:
                self.flag(name, 'companion-voice-not-pinned')
        if self.mode in ('app', 'zip'):
            if not self.plists:
                self.flag('Contents/Info.plist', 'missing-info-plist')
            for name, data in sorted(self.plists.items()):
                try:
                    identifier = plistlib.loads(data).get('CFBundleIdentifier')
                except Exception:
                    identifier = None
                if identifier != PUBLIC_BUNDLE_ID:
                    self.flag(name, 'unexpected-bundle-identifier')

    def tree(self, root: Path) -> None:
        for directory, dirs, files in os.walk(root, followlinks=False):
            current = Path(directory)
            # Filtering output is source-specific, not a way to hide runtime from an app audit.
            dirs[:] = sorted(d for d in dirs if not (self.mode == 'source' and d in SOURCE_SKIP))
            for d in list(dirs):
                path = current / d
                if path.is_symlink():
                    self.link(root, path)
                    dirs.remove(d)
            for filename in sorted(files):
                path = current / filename
                name = path.relative_to(root).as_posix()
                if path.is_symlink():
                    self.link(root, path)
                    continue
                if not self.name(name):
                    continue
                if not path.is_file():
                    self.flag(name, 'non-regular-file')
                    continue
                size = path.stat().st_size
                limit = MAX_SOURCE_FILE if self.mode == 'source' else MAX_RELEASE_FILE
                if size > limit:
                    self.flag(name, 'unexpected-large-file')
                    continue
                self.content(name, path.read_bytes())
        self.finish()

    def link(self, root: Path, path: Path) -> None:
        name = path.relative_to(root).as_posix()
        self.name(name)
        target = os.readlink(path)
        if os.path.isabs(target):
            self.flag(name, 'absolute-symlink')
            return
        try:
            path.resolve(strict=True).relative_to(root.resolve())
        except (ValueError, OSError, RuntimeError):
            self.flag(name, 'external-or-broken-symlink')

    def archive(self, path: Path) -> None:
        with zipfile.ZipFile(path) as archive:
            entries = archive.infolist()
            if sum(e.file_size for e in entries) > MAX_ARCHIVE_TOTAL:
                self.flag(path.name, 'unexpected-large-archive')
                return
            seen = set()
            for entry in entries:
                if entry.is_dir():
                    continue
                name = zip_entry_name(entry)
                if name in seen:
                    self.flag(name, 'duplicate-archive-entry')
                seen.add(name)
                if not self.name(name):
                    continue
                if entry.flag_bits & 1:
                    self.flag(name, 'encrypted-archive-entry')
                    continue
                if entry.file_size > MAX_RELEASE_FILE:
                    self.flag(name, 'unexpected-large-file')
                    continue
                with archive.open(entry) as stream:
                    data = stream.read(MAX_RELEASE_FILE + 1)
                if len(data) > MAX_RELEASE_FILE:
                    self.flag(name, 'unexpected-large-file')
                    continue
                if stat.S_ISLNK(entry.external_attr >> 16):
                    target = data.decode('utf-8', errors='replace')
                    resolved = PurePosixPath(name).parent / target
                    if target.startswith('/') or '..' in resolved.parts:
                        self.flag(name, 'unsafe-archive-symlink')
                self.content(name, data)
        self.finish()

    def history(self, repo: Path) -> None:
        """Every blob of every commit reachable from any ref. Paths are checked per commit tree."""
        def git(*args: str) -> bytes:
            return subprocess.run(['git', '-C', str(repo), *args], check=True, capture_output=True).stdout
        commits = git('rev-list', '--all').decode().split()
        blobs: dict[str, dict[str, set[str]]] = {}
        for commit in commits:
            for record in git('ls-tree', '-r', '-z', '--full-tree', commit).split(b'\0'):
                if not record:
                    continue
                meta, path = record.split(b'\t', 1)
                mode, kind, sha = meta.decode().split()
                if kind != 'blob':
                    continue
                entry = blobs.setdefault(sha, {'paths': set(), 'commits': set(), 'links': set()})
                entry['paths'].add(path.decode('utf-8', errors='replace'))
                entry['commits'].add(commit[:7])
                if mode == '120000':
                    entry['links'].add(path.decode('utf-8', errors='replace'))
        self.history_blobs = {sha: sorted(v['commits']) for sha, v in blobs.items()}
        self.history_paths: dict[tuple[str, str], str] = {}     # (blob, shown path) -> real path
        process = subprocess.Popen(['git', '-C', str(repo), 'cat-file', '--batch'],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        assert process.stdin and process.stdout
        try:
            for sha in sorted(blobs):
                process.stdin.write(sha.encode() + b'\n'); process.stdin.flush()
                header = process.stdout.readline().split()
                size = int(header[2])
                data = process.stdout.read(size); process.stdout.read(1)
                before = len(self.findings)
                for path in sorted(blobs[sha]['paths']):
                    self.history_paths[(sha, self.shown(path))] = path
                    self.name(path, history=True)
                    if size > MAX_RELEASE_FILE:
                        self.flag(path, 'unexpected-large-file')
                        continue
                    self.content(path, data)
                self.finish(history=True)
                self.voice_files.clear(); self.voice_json.clear(); self.plists.clear()
                for item in self.findings[before:]:
                    item['blob'] = sha
                    item['commits'] = ' '.join(sorted(blobs[sha]['commits']))
        finally:
            process.stdin.close()
            process.wait()

    def apply_accepted(self, accepted_path: Path) -> list[dict[str, str]]:
        """History hits that cannot be fixed without rewriting published history are listed, by
        immutable blob id and rule, in the accepted file. A content rule is waived for that blob
        wherever it appears (the bytes are already public; source mode still checks the tip). A path
        rule (PATH_RULES) is waived only for the paths the entry lists under "paths". Anything else fails."""
        accepted: dict[str, tuple[set[str], set[str]]] = {}
        if accepted_path.is_file():
            for item in json.loads(accepted_path.read_text(encoding='utf-8')).get('accepted', []):
                accepted[item['blob']] = (set(item['rules']), set(item.get('paths', [])))
        paths = getattr(self, 'history_paths', {})
        kept, waived = [], []
        for item in self.findings:
            rules, listed = accepted.get(item.get('blob', ''), (set(), set()))
            ok = item.get('rule') in rules
            if ok and item.get('rule') in PATH_RULES:
                ok = paths.get((item.get('blob', ''), item.get('path', ''))) in listed
            (waived if ok else kept).append(item)
        self.findings = kept
        return waived


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('path', type=Path)
    parser.add_argument('--mode', choices=('source', 'app', 'zip', 'history'), required=True)
    parser.add_argument('--deny-term', action='append', default=[], help='Private text to reject; never echoed.')
    parser.add_argument('--deny-terms-file', action='append', default=[], type=Path,
                        help='File of private terms, one per line; keep it outside the repository.')
    parser.add_argument('--accepted', type=Path, default=DEFAULT_ACCEPTED_HISTORY,
                        help='history mode: known, accepted hits by blob id (default: %(default)s).')
    parser.add_argument('--json', type=Path, help='Optional report path, preferably outside the source tree.')
    args = parser.parse_args()
    terms = load_deny_terms(args.deny_term, args.deny_terms_file, dict(os.environ))
    audit = Audit(args.mode, terms)
    waived: list[dict[str, str]] = []
    if args.mode == 'zip':
        audit.archive(args.path)
    elif args.mode == 'history':
        audit.history(args.path)
        waived = audit.apply_accepted(args.accepted)
    elif args.path.is_dir():
        audit.tree(args.path)
    else:
        parser.error('Expected a directory for source/app mode.')
    result = {'schema': 2, 'mode': args.mode, 'passed': not audit.findings,
              'private_terms_loaded': len(terms),
              'files_checked': len(audit.manifest),
              'bytes_checked': sum(int(f['bytes']) for f in audit.manifest),
              'findings': audit.findings, 'manifest': audit.manifest,
              'limits': 'Targeted content checks only; not a full privacy, vulnerability, or license audit.'}
    if args.mode == 'history':
        result['blobs_checked'] = len(getattr(audit, 'history_blobs', {}))
        result['accepted_history_findings'] = waived
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({k: v for k, v in result.items() if k != 'manifest'}, ensure_ascii=False, indent=2))
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
