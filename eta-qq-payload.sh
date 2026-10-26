#!/usr/bin/env bash
# eta-qq-payload.sh —— 一次写入 Eta QQ 通道全部改动（自解压，无需其他文件）
#
# 用法（仓库根目录执行）：
#   bash eta-qq-payload.sh .
#
# 由 Eta QQ 通道方案生成；可重复执行（已存在的补丁会跳过）。
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
import io.github.mangi.eta.core.safeLogType
import io.github.mangi.eta.core.AndroidAgentLogger
import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.contentOrNull

/**
 * QQ 通道配置。
 *
 * 单人自用场景不做设置页，直接读 App 私有外部目录下的 JSON：
 *   /sdcard/Android/data/io.github.mangi.eta/files/qq_channel.json
 *
 * 示例：
 * {
 *   "enabled": true,
 *   "wsUrl": "ws://192.168.1.10:3001",
 *   "accessToken": "changeme",
 *   "allowedUserIds": [123456789],
 *   "maxReplyChars": 1500,
 *   "allowTerminalTools": false,
 *   "allowDeviceTools": false
 * }
 */
internal data class QqChannelConfig(
    val enabled: Boolean,
    val wsUrl: String,
    val accessToken: String,
    val allowedUserIds: Set<Long>,
    val maxReplyChars: Int = 1500,
    /** 远程来源默认关闭所有高风险工具；仅当你明确知道后果时才改 true。 */
    val allowTerminalTools: Boolean = false,
    val allowDeviceTools: Boolean = false,
) {
    val valid: Boolean get() = enabled && wsUrl.isNotBlank() && allowedUserIds.isNotEmpty()

    companion object {
        private const val FILE_NAME = "qq_channel.json"
        private val json = Json { ignoreUnknownKeys = true; isLenient = true }

        fun file(context: Context): File =
            File(context.getExternalFilesDir(null) ?: context.filesDir, FILE_NAME)

        fun read(context: Context): QqChannelConfig? {
            val file = file(context)
            if (!file.isFile) return null
            return runCatching {
                val root = json.parseToJsonElement(file.readText()).jsonObject
                QqChannelConfig(
                    enabled = root["enabled"]?.jsonPrimitive?.booleanOrNull ?: false,
                    wsUrl = root["wsUrl"]?.jsonPrimitive?.contentOrNull.orEmpty().trim(),
                    accessToken = root["accessToken"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                    allowedUserIds = root["allowedUserIds"]?.jsonArray
                        ?.mapNotNull { it.jsonPrimitive.longOrNull }
                        ?.toSet()
                        .orEmpty(),
                    maxReplyChars = root["maxReplyChars"]?.jsonPrimitive?.intOrNull ?: 1500,
                    allowTerminalTools = root["allowTerminalTools"]?.jsonPrimitive?.booleanOrNull ?: false,
                    allowDeviceTools = root["allowDeviceTools"]?.jsonPrimitive?.booleanOrNull ?: false,
                )
            }.onFailure {
                AndroidAgentLogger.warn("QqChannel config parse failed: type=${it.safeLogType()}")
            }.getOrNull()
        }

        fun writeDefaultTemplate(context: Context): File {
            val file = file(context)
            if (!file.exists()) {
                file.parentFile?.mkdirs()
                runCatching {
                    file.writeText(
                        """
                        {
                          "enabled": false,
                          "wsUrl": "ws://127.0.0.1:3001",
                          "accessToken": "",
                          "allowedUserIds": [],
                          "maxReplyChars": 1500,
                          "allowTerminalTools": false,
                          "allowDeviceTools": false
                        }
                        """.trimIndent()
                    )
                }
            }
            return file
        }

        @Suppress("unused")
        private fun JsonObject.bool(key: String): Boolean? =
            this[key]?.jsonPrimitive?.booleanOrNull
    }
}
ETA_PAYLOAD_EOF

log "写入 QqChannelRunner.kt"
cat > "$CHANNEL_DIR/QqChannelRunner.kt" <<'ETA_PAYLOAD_EOF'
package io.github.mangi.eta.agent.channel

import android.content.Context
import io.github.mangi.eta.agent.runtime.AgentExecutionService
import io.github.mangi.eta.agent.runtime.AgentRuntimeClient
import io.github.mangi.eta.agent.runtime.AgentRuntimeWire
import io.github.mangi.eta.core.AndroidAgentLogger
import io.github.mangi.eta.data.repository.RuntimeConfigRepository
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * 把一条外部消息变成一次 Agent 运行。
 *
 * 复用聊天页完全相同的链路：RunRequest -> AgentRuntimeClient(Binder) -> AgentRuntimeService。
 * 这里不碰模型、不碰工具实现，只决定「带哪些工具开关」。
 */
internal class QqChannelRunner(
    private val context: Context,
    private val config: QqChannelConfig,
) {
    private val logger = AndroidAgentLogger
    private val client = AgentRuntimeClient(context, logger)

    /**
     * @param conversationKey 会话标识，同一 QQ 号固定，用于 Runtime 侧会话归档
     * @return 可直接发回 QQ 的文本（已含错误前缀）
     */
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
            // 入口侧一律收紧；Runtime 侧 AgentRuntimePolicy 还会与全局开关取交集。
            val constrained = modelConfig.copy(
                terminalTools = config.allowTerminalTools && modelConfig.terminalTools,
                deviceDirectTools = config.allowDeviceTools && modelConfig.deviceDirectTools,
                deviceSensitiveReadTools = false,
                deviceSensitiveActionTools = false,
            )
            val request = AgentRuntimeWire.RunRequest(
                runId = runId,
                prompt = prompt,
                config = constrained,
                images = emptyList(),
                modelSessionId = conversationKey,
                operation = AgentRuntimeWire.OP_CHAT,
            )
            val result = client.run(request) { /* 需要流式回传时在此收集 AssistantBlockDelta */ }
            if (result.ok) {
                result.content.ifBlank { "（模型没有返回内容）" }
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
}
ETA_PAYLOAD_EOF

log "写入 QqChannelService.kt"
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
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * QQ 通道前台服务。
 *
 * 职责：读配置 → 连 NapCat → 白名单过滤 → 串行跑 Agent → 回消息 → 断线重连。
 * 不参与模型与工具实现，真正的执行在 [QqChannelRunner]。
 */
internal class QqChannelService : Service() {

    private val job = SupervisorJob()
    private val scope = CoroutineScope(job + Dispatchers.IO)

    private val logger = AndroidAgentLogger
    private val running = AtomicBoolean(false)

    @Volatile
    private var client: OneBotClient? = null

    @Volatile
    private var runner: QqChannelRunner? = null

    private var config: QqChannelConfig? = null

    /** 单飞队列：一次只跑一个 run，最多积压 3 条。 */
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

    // ---- 连接管理 ----

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

            // 等待断开：连接期间轮询，断线后退避重连
            while (running.get() && oneBot.connected) delay(2_000L)
            if (!running.get()) break
            oneBot.close()
            client = null
            logger.info("QqChannel reconnect in ${backoffMs}ms")
            delay(backoffMs)
            backoffMs = (backoffMs * 2).coerceAtMost(60_000L)
        }
    }

    // ---- 消息处理 ----

    private fun handleEvent(event: OneBotEvent) {
        val cfg = config ?: return
        if (!event.isPrivateText) return
        if (event.selfId != 0L && event.userId == event.selfId) return // 自己发的
        if (event.userId !in cfg.allowedUserIds) {
            logger.info("QqChannel drop message from non-allowlisted user")
            return
        }
        if (event.text.contains("[CQ:image")) {
            reply(event.userId, "图片暂时看不懂，先发文字吧。")
            return
        }
        val queued = inbox.trySend(event)
        if (!queued.isSuccess) {
            reply(event.userId, "手上还有事没做完，稍等一下再发。")
        }
    }

    private suspend fun consumeLoop() {
        for (event in inbox) {
            val userRunner = runner ?: continue
            val conversationKey = "qq:${event.userId}"
            val answer = userRunner.run(prompt = event.text, conversationKey = conversationKey)
            reply(event.userId, answer)
        }
    }

    private fun reply(userId: Long, text: String) {
        val cfg = config ?: return
        val max = cfg.maxReplyChars.coerceIn(200, 4000)
        val chunks = text.chunked(max)
        val oneBot = client
        if (oneBot == null) {
            logger.warn("QqChannel reply dropped: not connected")
            return
        }
        chunks.forEachIndexed { index, chunk ->
            val prefix = if (chunks.size > 1) "(${index + 1}/${chunks.size}) " else ""
            oneBot.sendPrivateText(userId, prefix + chunk)
        }
    }

    // ---- 前台通知 ----

    private fun startAsForeground(text: String) {
        ensureChannel()
        startForeground(NOTIFICATION_ID, buildNotification(text))
    }

    private fun updateNotification(text: String) {
        runCatching {
            val manager = getSystemService(NotificationManager::class.java)
            manager?.notify(NOTIFICATION_ID, buildNotification(text))
        }
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "QQ 通道", NotificationManager.IMPORTANCE_LOW).apply {
                description = "维持与 NapCat 的长连接"
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

        /** 由 EtaApp 调用；配置无效时静默返回。 */
        fun startIfEnabled(context: Context) {
            val cfg = QqChannelConfig.read(context) ?: return
            if (!cfg.valid) return
            val intent = Intent(context, QqChannelService::class.java)
            runCatching { context.startForegroundService(intent) }
                .onFailure { AndroidAgentLogger.warn("QqChannel start failed: ${it.javaClass.simpleName}") }
        }
    }
}
ETA_PAYLOAD_EOF

log "写入 onebot/OneBotClient.kt"
cat > "$CHANNEL_DIR/onebot/OneBotClient.kt" <<'ETA_PAYLOAD_EOF'
package io.github.mangi.eta.agent.channel.onebot

import io.github.mangi.eta.core.AgentLogger
import java.util.concurrent.TimeUnit
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener

/**
 * OneBot v11 正向 WebSocket 客户端。
 *
 * 只做三件事：连、收事件、发动作。重连策略交给 [QqChannelService]。
 */
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
        .readTimeout(0, TimeUnit.MILLISECONDS) // WebSocket 常连接
        .pingInterval(45, TimeUnit.SECONDS)
        .retryOnConnectionFailure(true)
        .build()

    @Volatile
    private var socket: WebSocket? = null

    @Volatile
    var connected: Boolean = false
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
        val request = Request.Builder().url(url).build()
        socket = http.newWebSocket(request, Listener())
        logger.info("QqChannel connecting ws")
    }

    fun close() {
        connected = false
        runCatching {
            socket?.close(1000, "eta channel shutdown")
        }
        socket = null
        runCatching { http.dispatcher.executorService.shutdown() }
    }

    /** 调用 OneBot 动作，例如 send_private_msg。 */
    fun sendAction(action: String, params: JsonObject, echo: String = ""): Boolean {
        val ws = socket ?: return false
        val payload = buildJsonObject {
            put("action", action)
            put("params", params)
            if (echo.isNotBlank()) put("echo", echo)
        }
        return ws.send(json.encodeToString(JsonObject.serializer(), payload))
    }

    fun sendPrivateText(userId: Long, text: String): Boolean =
        sendAction(
            action = "send_private_msg",
            params = buildJsonObject {
                put("user_id", userId)
                put("message", text)
                put("auto_escape", true)
            },
        )

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
            if (event == null) return
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
}

/** 只保留通道真正需要的事件字段。 */
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
            val postType = root["post_type"]?.jsonPrimitive?.contentOrNullSafe() ?: return null
            val messageType = root["message_type"]?.jsonPrimitive?.contentOrNullSafe().orEmpty()
            val userId = root["user_id"]?.jsonPrimitive?.contentOrNullSafe()?.toLongOrNull() ?: 0L
            val selfId = root["self_id"]?.jsonPrimitive?.contentOrNullSafe()?.toLongOrNull() ?: 0L
            val messageId = root["message_id"]?.jsonPrimitive?.contentOrNullSafe()?.toLongOrNull() ?: 0L
            // raw_message 保留 CQ 码；纯文本优先用 raw_message
            val text = root["raw_message"]?.jsonPrimitive?.contentOrNullSafe()
                ?: root["message"]?.jsonPrimitive?.contentOrNullSafe()
                ?: ""
            return OneBotEvent(postType, messageType, userId, selfId, messageId, text.trim())
        }

        private fun kotlinx.serialization.json.JsonPrimitive.contentOrNullSafe(): String? =
            runCatching { content }.getOrNull()
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

log "完成"
