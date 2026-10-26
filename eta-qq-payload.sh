#!/usr/bin/env bash
# eta-qq-payload.sh  (v2)
# 一次写入 Eta QQ 通道全部代码（含：全工具开放、QQ 原生表情、图片表情包、握手竞态修复）
#
# 用法（仓库根目录）：bash eta-qq-payload.sh .
set -euo pipefail
REPO="${1:-.}"
log() { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m错误: %s\033[0m\n' "$*" >&2; exit 1; }

[ -f "$REPO/app/src/main/AndroidManifest.xml" ] || die "$REPO 不像 Eta 仓库根目录"
command -v python3 >/dev/null || die "需要 python3"

CHANNEL_DIR="$REPO/app/src/main/kotlin/io/github/mangi/eta/agent/channel"
mkdir -p "$CHANNEL_DIR/onebot"

log "写入 QqChannelConfig.kt"
cat > "$CHANNEL_DIR/QqChannelConfig.kt" <<'ETA_PAYLOAD_EOF'
package io.github.mangi.eta.agent.channel

import android.content.Context
import io.github.mangi.eta.core.AndroidAgentLogger
import io.github.mangi.eta.core.safeLogType
import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull

/**
 * QQ 通道配置：/sdcard/Android/data/io.github.mangi.eta/files/qq_channel.json
 */
internal data class QqChannelConfig(
    val enabled: Boolean,
    val wsUrl: String,
    val accessToken: String,
    val allowedUserIds: Set<Long>,
    val maxReplyChars: Int = 1500,
    val allowTerminalTools: Boolean = false,
    val allowDeviceTools: Boolean = false,
    val allowSensitiveReadTools: Boolean = false,
    val allowSensitiveActionTools: Boolean = false,
    val stickerDir: String = "",
    val enableStickers: Boolean = true,
) {
    val valid: Boolean get() = enabled && wsUrl.isNotBlank() && allowedUserIds.isNotEmpty()

    val resolvedStickerDir: File?
        get() = stickerDir.takeIf { it.isNotBlank() }?.let { File(it) }

    companion object {
        private const val FILE_NAME = "qq_channel.json"
        private val json = Json { ignoreUnknownKeys = true; isLenient = true }

        fun file(context: Context): File =
            File(context.getExternalFilesDir(null) ?: context.filesDir, FILE_NAME)

        fun defaultStickerDir(context: Context): File =
            File(context.getExternalFilesDir(null) ?: context.filesDir, "stickers")

        fun read(context: Context): QqChannelConfig? {
            val f = file(context)
            if (!f.isFile) return null
            return runCatching {
                val root = json.parseToJsonElement(f.readText()).jsonObject
                QqChannelConfig(
                    enabled = root["enabled"]?.jsonPrimitive?.booleanOrNull ?: false,
                    wsUrl = root["wsUrl"]?.jsonPrimitive?.contentOrNull.orEmpty().trim(),
                    accessToken = root["accessToken"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                    allowedUserIds = root["allowedUserIds"]?.jsonArray
                        ?.mapNotNull { it.jsonPrimitive.longOrNull }?.toSet().orEmpty(),
                    maxReplyChars = root["maxReplyChars"]?.jsonPrimitive?.intOrNull ?: 1500,
                    allowTerminalTools = root["allowTerminalTools"]?.jsonPrimitive?.booleanOrNull ?: false,
                    allowDeviceTools = root["allowDeviceTools"]?.jsonPrimitive?.booleanOrNull ?: false,
                    allowSensitiveReadTools = root["allowSensitiveReadTools"]?.jsonPrimitive?.booleanOrNull ?: false,
                    allowSensitiveActionTools = root["allowSensitiveActionTools"]?.jsonPrimitive?.booleanOrNull ?: false,
                    stickerDir = root["stickerDir"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                    enableStickers = root["enableStickers"]?.jsonPrimitive?.booleanOrNull ?: true,
                )
            }.onFailure {
                AndroidAgentLogger.warn("QqChannel config parse failed: type=${it.safeLogType()}")
            }.getOrNull()
        }

        fun writeDefaultTemplate(context: Context): File {
            val f = file(context)
            if (!f.exists()) {
                f.parentFile?.mkdirs()
                runCatching {
                    f.writeText(
                        """
                        {
                          "enabled": false,
                          "wsUrl": "ws://127.0.0.1:5800",
                          "accessToken": "",
                          "allowedUserIds": [],
                          "maxReplyChars": 1500,
                          "allowTerminalTools": true,
                          "allowDeviceTools": true,
                          "allowSensitiveReadTools": true,
                          "allowSensitiveActionTools": true,
                          "enableStickers": true,
                          "stickerDir": ""
                        }
                        """.trimIndent()
                    )
                }
                defaultStickerDir(context).mkdirs()
            }
            return f
        }
    }
}
ETA_PAYLOAD_EOF

log "写入 OneBotClient.kt（消息段支持：文本/原生表情/图片）"
cat > "$CHANNEL_DIR/onebot/OneBotClient.kt" <<'ETA_PAYLOAD_EOF'
package io.github.mangi.eta.agent.channel.onebot

import io.github.mangi.eta.core.AgentLogger
import java.io.File
import java.util.concurrent.TimeUnit
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener

internal class OneBotClient(
    private val logger: AgentLogger,
    private val wsUrl: String,
    private val accessToken: String,
    private val onEvent: (OneBotEvent) -> Unit,
    private val onConnectionChanged: (Boolean) -> Unit,
) {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    private val http = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .pingInterval(45, TimeUnit.SECONDS)
        .retryOnConnectionFailure(true)
        .build()

    @Volatile private var socket: WebSocket? = null
    @Volatile var connected: Boolean = false
        private set

    fun connect() {
        val url = buildString {
            append(wsUrl.trim())
            if (accessToken.isNotBlank() && !wsUrl.contains("access_token=")) {
                append(if (wsUrl.contains('?')) '&' else '?')
                append("access_token=")
                append(java.net.URLEncoder.encode(accessToken, "UTF-8"))
            }
        }
        socket = http.newWebSocket(Request.Builder().url(url).build(), Listener())
        logger.info("QqChannel connecting ws")
    }

    fun close() {
        connected = false
        runCatching { socket?.close(1000, "eta channel shutdown") }
        socket = null
        runCatching { http.dispatcher.executorService.shutdown() }
    }

    fun sendAction(action: String, params: JsonObject, echo: String = ""): Boolean {
        val ws = socket ?: return false
        val payload = buildJsonObject {
            put("action", action)
            put("params", params)
            if (echo.isNotBlank()) put("echo", echo)
        }
        return ws.send(json.encodeToString(JsonObject.serializer(), payload))
    }

    /** 发送一条消息，message 为 OneBot 消息段数组。 */
    fun sendPrivateMessage(userId: Long, segments: JsonArray): Boolean {
        if (segments.isEmpty()) return false
        return sendAction(
            action = "send_private_msg",
            params = buildJsonObject {
                put("user_id", userId)
                put("message", segments)
            },
        )
    }

    private inner class Listener : WebSocketListener() {
        override fun onOpen(webSocket: WebSocket, response: Response) {
            connected = true
            logger.info("QqChannel ws open")
            onConnectionChanged(true)
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            val event = runCatching {
                OneBotEvent.parse(json.parseToJsonElement(text).jsonObject)
            }.onFailure {
                logger.warn("QqChannel bad event payload: len=${text.length}")
            }.getOrNull() ?: return
            onEvent(event)
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            connected = false
            logger.warn("QqChannel ws failure: type=${t.javaClass.simpleName} code=${response?.code ?: -1}")
            onConnectionChanged(false)
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            connected = false
            logger.info("QqChannel ws closed: code=$code")
            onConnectionChanged(false)
        }
    }

    companion object {
        fun textSegment(text: String): JsonObject = buildJsonObject {
            put("type", "text")
            put("data", buildJsonObject { put("text", text) })
        }

        fun faceSegment(faceId: String): JsonObject = buildJsonObject {
            put("type", "face")
            put("data", buildJsonObject { put("id", faceId) })
        }

        fun imageSegment(file: File): JsonObject = buildJsonObject {
            put("type", "image")
            put("data", buildJsonObject { put("file", "file://" + file.absolutePath) })
        }

        fun messageOf(vararg segments: JsonObject): JsonArray = buildJsonArray {
            segments.forEach { add(it) }
        }
    }
}

internal data class OneBotEvent(
    val postType: String,
    val messageType: String,
    val userId: Long,
    val selfId: Long,
    val messageId: Long,
    val text: String,
) {
    val isPrivateText: Boolean
        get() = postType == "message" && messageType == "private" && text.isNotBlank()

    companion object {
        fun parse(root: JsonObject): OneBotEvent? {
            val postType = root["post_type"]?.jsonPrimitive?.contentSafe() ?: return null
            val messageType = root["message_type"]?.jsonPrimitive?.contentSafe().orEmpty()
            val userId = root["user_id"]?.jsonPrimitive?.contentSafe()?.toLongOrNull() ?: 0L
            val selfId = root["self_id"]?.jsonPrimitive?.contentSafe()?.toLongOrNull() ?: 0L
            val messageId = root["message_id"]?.jsonPrimitive?.contentSafe()?.toLongOrNull() ?: 0L
            val text = root["raw_message"]?.jsonPrimitive?.contentSafe()
                ?: root["message"]?.jsonPrimitive?.contentSafe()
                ?: ""
            return OneBotEvent(postType, messageType, userId, selfId, messageId, text.trim())
        }

        private fun kotlinx.serialization.json.JsonPrimitive.contentSafe(): String? =
            runCatching { content }.getOrNull()
    }
}
ETA_PAYLOAD_EOF

log "写入 QqChannelRunner.kt（全工具开放 + 表情指令注入）"
cat > "$CHANNEL_DIR/QqChannelRunner.kt" <<'ETA_PAYLOAD_EOF'
package io.github.mangi.eta.agent.channel

import android.content.Context
import io.github.mangi.eta.agent.runtime.AgentExecutionService
import io.github.mangi.eta.agent.runtime.AgentRuntimeClient
import io.github.mangi.eta.agent.runtime.AgentRuntimeWire
import io.github.mangi.eta.core.AndroidAgentLogger
import io.github.mangi.eta.data.repository.RuntimeConfigRepository
import java.io.File
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

internal class QqChannelRunner(
    private val context: Context,
    private val config: QqChannelConfig,
) {
    private val logger = AndroidAgentLogger
    private val client = AgentRuntimeClient(context, logger)

    suspend fun run(prompt: String, conversationKey: String): String = withContext(Dispatchers.IO) {
        val modelConfig = runCatching { RuntimeConfigRepository.currentRuntimeConfig() }
            .onFailure { logger.warn("QqChannel load model config failed: ${it.javaClass.simpleName}") }
            .getOrNull()
            ?: return@withContext "❌ 还没有可用的模型配置，请先在 Eta 里选好服务商和模型。"

        val runId = "qq-" + UUID.randomUUID().toString()
        val executionId = "qq-channel:$runId"
        val acquired = AgentExecutionService.acquire(
            context,
            executionId,
            onStop = {
                logger.info("QqChannel execution stopped by user")
                client.cancelRun(runId)
            },
        )
        if (!acquired) return@withContext "❌ 当前无法取得前台执行资格，请稍后重试。"

        try {
            // 全开：按配置放开工具；Runtime 侧 AgentRuntimePolicy 仍会与全局开关取交集
            val constrained = modelConfig.copy(
                terminalTools = config.allowTerminalTools && modelConfig.terminalTools,
                browserTools = modelConfig.browserTools,
                deviceDirectTools = config.allowDeviceTools && modelConfig.deviceDirectTools,
                deviceSensitiveReadTools = config.allowSensitiveReadTools && modelConfig.deviceSensitiveReadTools,
                deviceSensitiveActionTools = config.allowSensitiveActionTools && modelConfig.deviceSensitiveActionTools,
            )
            val request = AgentRuntimeWire.RunRequest(
                runId = runId,
                prompt = decorate(prompt),
                config = constrained,
                images = emptyList(),
                modelSessionId = conversationKey,
                operation = AgentRuntimeWire.OP_CHAT,
            )
            val result = client.run(request) { }
            if (result.ok) {
                result.content.ifBlank { "（没返回内容）" }
            } else {
                "❌ ${result.error?.takeIf { it.isNotBlank() } ?: "执行失败"}"
            }
        } catch (throwable: Throwable) {
            logger.warn("QqChannel run failed: type=${throwable.javaClass.simpleName}")
            "❌ 执行异常：${throwable.javaClass.simpleName}"
        } finally {
            runCatching { AgentExecutionService.release(executionId) }
        }
    }

    /** 把"怎么发表情"的说明拼在用户消息后面，模型才知道有哪些可用标记。 */
    private fun decorate(prompt: String): String {
        if (!config.enableStickers) return prompt
        val faces = "0笑,1撇嘴,2色,4得意,5流泪,6害羞,9大哭,13惊讶,14调皮,17害羞,21白眼,23鄙视,25心碎,32疑问,33衰,36吐血,49拥抱,53蛋糕,66爱心,74太阳,75月亮,84炸弹,85刀,90亲亲,96汗,101鄙视,104哈欠,105酷,107右哼哼,109左哼哼,111可怜,116调皮,118抱拳,120挥手,124OK,178斜眼,182笑哭,183白眼,185飞吻,187亲,188憧憬,201点赞"
        val stickers = listStickerNames()
        val stickerLine = if (stickers.isEmpty()) {
            "本地表情包：暂无（跳过）"
        } else {
            "本地表情包可选名字：${stickers.joinToString("、")}"
        }
        return buildString {
            append(prompt)
            append("\n\n[发送表情的规则]\n")
            append("- 想发 QQ 原生表情，在回复里写 [[face:ID]]，例如 [[face:14]] 是调皮，[[face:178]] 是笑哭。可选：")
            append(faces)
            append("\n- ")
            append(stickerLine)
            append("\n- 想发本地表情包，写 [[图:名字]]，名字要严格用上面列表里的词。\n")
            append("- 一条消息最多 1 个表情，别连着发。这些标记会由程序转成真表情，不要解释它们。")
        }
    }

    private fun listStickerNames(): List<String> {
        val dir = config.resolvedStickerDir ?: QqChannelConfig.defaultStickerDir(context)
        if (!dir.isDirectory) return emptyList()
        return dir.listFiles()
            ?.filter { it.isFile && it.extension.lowercase() in setOf("png", "jpg", "jpeg", "gif", "webp") }
            ?.map { it.nameWithoutExtension }
            ?.sorted()
            ?.take(60)
            .orEmpty()
    }
}
ETA_PAYLOAD_EOF

log "写入 QqChannelService.kt（消息段解析 + 表情发送 + 握手修复）"
cat > "$CHANNEL_DIR/QqChannelService.kt" <<'ETA_PAYLOAD_EOF'
package io.github.mangi.eta.agent.channel

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import io.github.mangi.eta.agent.channel.onebot.OneBotClient
import io.github.mangi.eta.agent.channel.onebot.OneBotEvent
import io.github.mangi.eta.core.AndroidAgentLogger
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonArray

internal class QqChannelService : Service() {

    private val job = SupervisorJob()
    private val scope = CoroutineScope(job + Dispatchers.IO)
    private val logger = AndroidAgentLogger
    private val running = AtomicBoolean(false)

    @Volatile private var client: OneBotClient? = null
    @Volatile private var runner: QqChannelRunner? = null
    private var config: QqChannelConfig? = null

    private val inbox = Channel<OneBotEvent>(capacity = 3)

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        startAsForeground("正在连接 QQ 通道…")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val cfg = QqChannelConfig.read(this)
        if (cfg == null || !cfg.valid) {
            logger.info("QqChannel disabled or invalid config, service stops")
            stopSelf()
            return START_NOT_STICKY
        }
        config = cfg
        (cfg.resolvedStickerDir ?: QqChannelConfig.defaultStickerDir(this)).mkdirs()
        runner = QqChannelRunner(this, cfg)
        if (running.compareAndSet(false, true)) {
            scope.launch { connectionLoop(cfg) }
            scope.launch { consumeLoop() }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        running.set(false)
        inbox.close()
        client?.close()
        client = null
        job.cancel()
        super.onDestroy()
    }

    private suspend fun connectionLoop(cfg: QqChannelConfig) {
        var backoffMs = 3_000L
        while (running.get() && scope.isActive) {
            val oneBot = OneBotClient(
                logger = logger,
                wsUrl = cfg.wsUrl,
                accessToken = cfg.accessToken,
                onEvent = { event -> handleEvent(event) },
                onConnectionChanged = { connected ->
                    if (connected) backoffMs = 3_000L
                    updateNotification(if (connected) "QQ 通道已连接" else "QQ 通道断开，重连中…")
                },
            )
            client = oneBot
            oneBot.connect()

            // 先等握手完成（最多 15 秒），没连上就当本次失败
            var graceMs = 0
            while (running.get() && !oneBot.connected && graceMs < 15_000) {
                delay(200L)
                graceMs += 200
            }
            // 握手成功后保持，直到断开
            while (running.get() && oneBot.connected) delay(1_000L)

            if (!running.get()) break
            oneBot.close()
            client = null
            logger.info("QqChannel reconnect in ${backoffMs}ms")
            delay(backoffMs)
            backoffMs = (backoffMs * 2).coerceAtMost(60_000L)
        }
    }

    private fun handleEvent(event: OneBotEvent) {
        val cfg = config ?: return
        if (!event.isPrivateText) return
        if (event.selfId != 0L && event.userId == event.selfId) return
        if (event.userId !in cfg.allowedUserIds) {
            logger.info("QqChannel drop message from non-allowlisted user")
            return
        }
        if (inbox.trySend(event).isFailure) {
            reply(event.userId, "手上还有事没做完，等我一下嘛")
        }
    }

    private suspend fun consumeLoop() {
        for (event in inbox) {
            val userRunner = runner ?: continue
            val answer = userRunner.run(prompt = event.text, conversationKey = "qq:${event.userId}")
            reply(event.userId, answer)
        }
    }

    /** 把模型输出里的 [[face:ID]] / [[图:名字]] 转成真正的表情消息段。 */
    private fun reply(userId: Long, raw: String) {
        val cfg = config ?: return
        val oneBot = client ?: run {
            logger.warn("QqChannel reply dropped: not connected")
            return
        }
        val batches = buildBatches(raw, cfg)
        for (segments in batches) {
            oneBot.sendPrivateMessage(userId, segments)
        }
    }

    private fun buildBatches(raw: String, cfg: QqChannelConfig): List<JsonArray> {
        val marker = Regex("\\[\\[(face|图|image|sticker):([^\\]]+)\\]\\]")
        val stickerDir = cfg.resolvedStickerDir ?: QqChannelConfig.defaultStickerDir(this)
        val batches = mutableListOf<JsonArray>()
        var pending = mutableListOf<JsonObject>()
        var textLen = 0
        val maxText = cfg.maxReplyChars.coerceIn(200, 3000)

        fun flush() {
            if (pending.isNotEmpty()) {
                batches.add(buildJsonArray { pending.forEach { add(it) } })
                pending = mutableListOf()
                textLen = 0
            }
        }

        var cursor = 0
        for (match in marker.findAll(raw)) {
            val textBefore = raw.substring(cursor, match.range.first)
            cursor = match.range.last + 1
            if (textBefore.isNotBlank()) {
                for (chunk in textBefore.chunked(maxText)) {
                    pending.add(OneBotClient.textSegment(chunk))
                    textLen += chunk.length
                    if (textLen >= maxText) flush()
                }
            }
            val kind = match.groupValues[1]
            val value = match.groupValues[2].trim()
            if (cfg.enableStickers) {
                if (kind == "face") {
                    pending.add(OneBotClient.faceSegment(value))
                } else {
                    resolveSticker(stickerDir, value)?.let { pending.add(OneBotClient.imageSegment(it)) }
                }
            }
        }
        val tail = raw.substring(cursor)
        if (tail.isNotBlank()) {
            for (chunk in tail.chunked(maxText)) {
                pending.add(OneBotClient.textSegment(chunk))
                textLen += chunk.length
                if (textLen >= maxText) flush()
            }
        }
        flush()
        return batches
    }

    private fun resolveSticker(dir: File, name: String): File? {
        if (!dir.isDirectory) return null
        val files = dir.listFiles()?.filter { it.isFile } ?: return null
        return files.firstOrNull { it.nameWithoutExtension.equals(name, ignoreCase = true) }
            ?: files.firstOrNull { it.nameWithoutExtension.contains(name) }
            ?: files.firstOrNull { name.contains(it.nameWithoutExtension) }
    }

    private fun startAsForeground(text: String) {
        ensureChannel()
        startForeground(NOTIFICATION_ID, buildNotification(text))
    }

    private fun updateNotification(text: String) {
        runCatching {
            getSystemService(NotificationManager::class.java)?.notify(NOTIFICATION_ID, buildNotification(text))
        }
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "QQ 通道", NotificationManager.IMPORTANCE_LOW).apply {
                description = "维持与协议端的连接"
                setShowBadge(false)
            }
        )
    }

    private fun buildNotification(text: String): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("Eta · QQ 通道")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "eta_qq_channel"
        private const val NOTIFICATION_ID = 0x9101

        fun startIfEnabled(context: Context) {
            val cfg = QqChannelConfig.read(context) ?: return
            if (!cfg.valid) return
            runCatching {
                context.startForegroundService(Intent(context, QqChannelService::class.java))
            }.onFailure { AndroidAgentLogger.warn("QqChannel start failed: ${it.javaClass.simpleName}") }
        }
    }
}
ETA_PAYLOAD_EOF

log "修改 AndroidManifest.xml"
python3 - "$REPO/app/src/main/AndroidManifest.xml" <<'PY'
import sys, io
path = sys.argv[1]
src = io.open(path, encoding='utf-8').read()
if 'QqChannelService' in src:
    print('  已存在，跳过'); sys.exit(0)
block = '''
        <service
            android:name=".agent.channel.QqChannelService"
            android:exported="false"
            android:foregroundServiceType="specialUse">
            <property
                android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE"
                android:value="Keeps a user-configured OneBot WebSocket channel connected for personal messaging" />
        </service>

'''
anchor = '    </application>'
if anchor not in src:
    sys.exit('  找不到 </application>')
src = src.replace(anchor, block + anchor, 1)
io.open(path, 'w', encoding='utf-8').write(src)
print('  已插入 <service>')
PY

log "修改 EtaApp.kt"
python3 - "$REPO/app/src/main/kotlin/io/github/mangi/eta/EtaApp.kt" <<'PY'
import sys, io
path = sys.argv[1]
src = io.open(path, encoding='utf-8').read()
if 'QqChannelService' in src:
    print('  已存在，跳过'); sys.exit(0)
imports = ('import io.github.mangi.eta.agent.channel.QqChannelConfig\n'
           'import io.github.mangi.eta.agent.channel.QqChannelService\n')
idx = src.index('\nimport ')
src = src[:idx+1] + imports + src[idx+1:]
anchor = '        XposedServiceHelper.registerListener(this)\n'
if anchor not in src:
    sys.exit('  找不到 XposedServiceHelper.registerListener(this)')
launch = ('        applicationScope.launch {\n'
          '            QqChannelConfig.writeDefaultTemplate(this@EtaApp)\n'
          '            QqChannelService.startIfEnabled(this@EtaApp)\n'
          '        }\n')
src = src.replace(anchor, anchor + launch, 1)
io.open(path, 'w', encoding='utf-8').write(src)
print('  已插入 import + 启动代码')
PY

log "完成（v2：全工具 + 原生表情 + 图片表情包 + 握手修复）"
