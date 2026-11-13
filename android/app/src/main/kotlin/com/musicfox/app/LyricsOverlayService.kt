package com.musicfox.app

import android.animation.ValueAnimator
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.IBinder
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.LinearLayout
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * 悬浮歌词窗服务（移植自 RawS-Music DesktopLyricService）。
 *
 * 数据全部由 Flutter 侧驱动（歌词/播放进度/设置经 MethodChannel 推送），
 * 本服务只负责渲染与交互：卡拉OK逐字填充、拖拽移动、单击/长按唤出控制条、
 * 锁定（通知解锁）、颜色/字号循环。控制动作经事件通道回调 Flutter 执行播放。
 */
class LyricsOverlayService : Service() {
    private lateinit var windowManager: WindowManager
    private lateinit var notificationManager: NotificationManager
    private var rootView: LinearLayout? = null
    private var lyricView: LyricsOverlayView? = null
    private var controlsView: LinearLayout? = null
    private var lockRowView: FrameLayout? = null
    private var playPauseButton: ImageButton? = null
    private var layoutParams: WindowManager.LayoutParams? = null
    private var eventsChannel: MethodChannel? = null

    // 由 Flutter 推送的运行时数据（内存态，持久化在 Flutter 侧）。
    private var lyricsJson = ""
    private var positionMs = 0L
    private var playing = false
    private var textColor = Color.WHITE
    private var unplayedColor = 0
    private var opacity = 1f
    private var fontScale = 1f
    private var secondaryScale = 1f
    private var showTranslation = true
    private var showRomanization = false
    private var showBackground = true
    private var showNextLine = false
    private var hideWhenPaused = false
    // 是否已收到 Flutter 侧推来的播放态：未收到前窗口保持不可见
    private var playbackSynced = false
    // 补词请求限频（见 requestLyricsIfNeeded）
    private var lastLyricsRequestAt = 0L
    private var lyricsRequestCount = 0
    private var hideInLandscape = false
    private var widthPercent = 92
    private var useLyricFont = false
    private var lyricFontPath = ""
    private var locked = false
    private var xPos = 0
    private var yPos = 96

    private var downX = 0f
    private var downY = 0f
    private var startX = 0
    private var startY = 0
    private var movedDuringTouch = false
    private var longPressTriggered = false

    private val hideControlsRunnable = Runnable { hideControls() }
    private val longPressRunnable = Runnable {
        longPressTriggered = true
        showControlsWithAnimation()
    }

    // 半透明底板（触控即显示，按住期间常显，无操作 3 秒自动淡出），alpha 0=隐藏 255=显示。
    private var rootBg: GradientDrawable? = null
    private var bgAnimator: ValueAnimator? = null
    private val hideBgRunnable = Runnable { hideBackgroundPanel() }

    override fun onCreate() {
        super.onCreate()
        instance = this
        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager
        notificationManager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        // 恢复上次的设置：一是本进程内 Flutter 推送早于服务创建（startService 异步，
        // 那些推送被缓冲在 companion 里），二是更早一次运行留在本地的设置。
        // 缺了这一步就会拿上面手写的默认值建窗，表现正是「字号/宽度/位置记不住」。
        restoreSettings()
        pendingLyrics?.let { lyricsJson = it }
        pendingPlayback?.let { playback ->
            positionMs = playback.first
            playing = playback.second
            playbackSynced = true
        }
        pendingLocked?.let { locked = it }
        Log.d(TAG, "onCreate restored settings=${pendingSettings != null} locked=$locked")
        FlutterMessengerHolder.messenger?.let {
            eventsChannel = MethodChannel(it, EVENTS_CHANNEL)
        }
    }

    private fun restoreSettings() {
        val json = pendingSettings
            ?: runCatching {
                getSharedPreferences(PREFS_NAME, MODE_PRIVATE).getString(KEY_SETTINGS, null)
            }.getOrNull()
        if (json.isNullOrBlank()) return
        pendingSettings = json
        parseSettings(json)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_HIDE -> disableAndStop()
            ACTION_UNLOCK -> {
                locked = false
                applySettings(revealControls = true)
                // 通知解锁需同步回 Flutter 持久化锁定状态。
                emitEvent("onUnlock")
            }
            else -> showOverlayIfAllowed()
        }
        // START_NOT_STICKY：悬浮窗完全依赖 Flutter 引擎推送歌词/进度，
        // 进程死后被系统在新进程里拉起只会得到一个无数据源的僵尸悬浮窗
        // + 常驻通知（main() 重跑还会连带拉起媒体通知，表现为"划掉多任务
        // 又回来了"）。引擎活着时由 Flutter 侧按需重启，无需 sticky 复活。
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // 任务被划掉即随宿主一起退场：清窗 + 撤通知 + stopSelf，
        // 避免与 Dart 侧 exit(0) 竞争期间留下残留通知或被再次调度。
        disableAndStop()
        super.onTaskRemoved(rootIntent)
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        updateVisibility()
        updateWindowLayout()
    }

    override fun onDestroy() {
        instance = null
        rootView?.removeCallbacks(hideControlsRunnable)
        rootView?.removeCallbacks(hideBgRunnable)
        bgAnimator?.cancel()
        bgAnimator = null
        rootBg = null
        rootView?.let { runCatching { windowManager.removeView(it) } }
        rootView = null
        lyricView = null
        controlsView = null
        playPauseButton = null
        layoutParams = null
        notificationManager.cancel(NOTIFICATION_ID)
        super.onDestroy()
    }

    // ---- 数据入口（由 MainActivity 的 MethodChannel 转发） ----

    fun setLyrics(json: String) {
        lyricsJson = json
        val parsed = parseLyrics(json)
        // 拿到非空歌词就把补词计数清零：换歌后重新给足重试机会。
        if (parsed.isNotEmpty()) lyricsRequestCount = 0
        Log.d(TAG, "setLyrics jsonLen=${json.length} lines=${parsed.size}")
        lyricView?.setLyrics(parsed)
    }

    /**
     * 播着但一行歌词都没有时向 Flutter 要一次。切歌瞬间插件引擎在解析播放地址，
     * 歌词请求很容易空手而归；以前没有这条回补，整首歌就停在「等待播放」。
     * 限频 3 秒一次、最多 4 次，避免无歌词的歌把链路刷爆。
     */
    private fun requestLyricsIfNeeded() {
        if (lyricView?.hasLyrics() != false) return
        if (lyricsRequestCount >= MAX_LYRICS_REQUESTS) return
        val now = SystemClock.elapsedRealtime()
        if (now - lastLyricsRequestAt < LYRICS_REQUEST_INTERVAL_MS) return
        lastLyricsRequestAt = now
        lyricsRequestCount++
        Log.d(TAG, "requestLyrics #$lyricsRequestCount")
        emitEvent("onNeedLyrics")
    }

    fun setPlayback(posMs: Long, isPlaying: Boolean) {
        positionMs = posMs
        playing = isPlaying
        playbackSynced = true
        lyricView?.setPlayback(posMs, isPlaying)
        playPauseButton?.setImageResource(if (isPlaying) R.drawable.ic_pause else R.drawable.ic_play)
        updateVisibility(isPlaying)
        if (isPlaying) requestLyricsIfNeeded()
    }

    fun setSettings(json: String) {
        // 空串直接忽略：否则 parseSettings 早退、applySettings 会把窗口按默认值重排
        if (json.isBlank()) return
        pendingSettings = json
        parseSettings(json)
        applySettings(revealControls = false)
    }

    fun setLocked(lock: Boolean) {
        locked = lock
        applySettings(revealControls = false)
    }

    fun resetPosition() {
        xPos = 0
        yPos = 96
        persistPosition(0, 96)
        layoutParams?.let { params ->
            params.x = 0
            params.y = 96
            rootView?.let { runCatching { windowManager.updateViewLayout(it, params) } }
        }
    }

    /** 位置落在本地，服务被系统回收重建后仍能回到用户拖到的地方。 */
    private fun persistPosition(x: Int, y: Int) {
        val base = pendingSettings ?: return
        runCatching {
            val patched = JSONObject(base).put("x", x).put("y", y).toString()
            pendingSettings = patched
            getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
                .edit()
                .putString(KEY_SETTINGS, patched)
                .apply()
        }
    }

    // ---- 生命周期 ----

    private fun showOverlayIfAllowed() {
        if (!canDrawOverlay()) {
            stopSelf()
            return
        }
        if (rootView == null) addOverlay()
        applySettings(revealControls = false)
        lyricView?.setLyrics(parseLyrics(lyricsJson))
        lyricView?.setPlayback(positionMs, playing)
    }

    private fun addOverlay() {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(8), dp(4), dp(8), dp(4))
            // 半透明圆角底板：背景与控制条作为同一块面板，一起淡入/淡出。
            // 初始隐藏（alpha 0），点击/拖拽整体唤出，数秒无操作整体淡出，避免"只出背景没控件"。
            background = GradientDrawable().apply {
                cornerRadius = dp(16).toFloat()
                setColor(Color.argb(92, 15, 15, 17))
                alpha = 0
            }.also { rootBg = it }
        }
        val lockRow = createLockRow()
        val lyric = LyricsOverlayView(this).apply {
            touchHandler = ::onDrag
            onNeedsLyrics = ::requestLyricsIfNeeded
        }
        val controls = createControls()
        root.addView(
            lockRow,
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                dp(38)
            )
        )
        root.addView(
            lyric,
            LinearLayout.LayoutParams(overlayWidth(), overlayHeight())
        )
        root.addView(
            controls,
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                dp(54)
            ).apply { gravity = Gravity.CENTER_HORIZONTAL }
        )

        val baseFlags = WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
            WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
            WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }
        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            type,
            if (locked) baseFlags or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE else baseFlags,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
            x = xPos
            y = yPos
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            }
        }

        rootView = root
        lyricView = lyric
        controlsView = controls
        lockRowView = lockRow
        layoutParams = params
        controls.visibility = View.GONE
        lockRow.visibility = View.GONE
        windowManager.addView(root, params)
        clampToScreen(root, params)
        windowManager.updateViewLayout(root, params)
    }

    private fun createControls(): LinearLayout {
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(dp(5), dp(4), dp(5), dp(4))
            background = GradientDrawable().apply {
                cornerRadius = dp(24).toFloat()
                setColor(Color.argb(176, 30, 30, 30))
            }
            addIconControl(R.drawable.ic_skip_previous, "上一首") {
                emitEvent("onPrevious")
            }
            playPauseButton = addIconControl(
                R.drawable.ic_play,
                "播放/暂停"
            ) {
                emitEvent("onTogglePlayback")
            }
            addIconControl(R.drawable.ic_skip_next, "下一首") {
                emitEvent("onNext")
            }
        }
    }

    /** 歌词上方右侧的锁定入口（解锁走系统通知）。 */
    private fun createLockRow(): FrameLayout {
        val row = FrameLayout(this).apply { clipChildren = false }
        val button = ImageButton(this).apply {
            setImageResource(R.drawable.ic_lock_outline)
            setColorFilter(Color.WHITE)
            contentDescription = "锁定"
            scaleType = ImageView.ScaleType.CENTER
            background = controlBackground()
            setPadding(dp(8), dp(8), dp(8), dp(8))
            setOnClickListener { emitEvent("onLock") }
        }
        row.addView(
            button,
            FrameLayout.LayoutParams(dp(34), dp(34)).apply {
                gravity = Gravity.END or Gravity.CENTER_VERTICAL
                marginEnd = dp(2)
            }
        )
        return row
    }

    private fun LinearLayout.addIconControl(
        icon: Int,
        description: String,
        action: () -> Unit
    ): ImageButton {
        val button = ImageButton(context).apply {
            setImageResource(icon)
            setColorFilter(Color.WHITE)
            contentDescription = description
            scaleType = ImageView.ScaleType.CENTER
            background = controlBackground()
            setPadding(dp(9), dp(9), dp(9), dp(9))
            setOnClickListener {
                action()
                // 继续操作：底板显示时长顺延。
                showBackgroundPanel()
                scheduleControlsAutoHide()
            }
        }
        addView(button, controlLayoutParams())
        return button
    }

    private fun controlLayoutParams() = LinearLayout.LayoutParams(dp(42), dp(42)).apply {
        marginStart = dp(2)
        marginEnd = dp(2)
    }

    private fun controlBackground() = GradientDrawable().apply {
        shape = GradientDrawable.OVAL
        setColor(Color.argb(52, 255, 255, 255))
    }

    private fun emitEvent(method: String, args: Any? = null) {
        runCatching { eventsChannel?.invokeMethod(method, args) }
    }

    // ---- 设置 ----

    private fun parseSettings(json: String) {
        if (json.isBlank()) return
        runCatching {
            val o = JSONObject(json)
            textColor = o.optInt("textColor", Color.WHITE)
            unplayedColor = o.optInt("unplayedColor", 0)
            opacity = (o.optInt("opacity", 100) / 100f).coerceIn(0f, 1f)
            fontScale = (o.optInt("fontScale", 100) / 100f).coerceIn(0.1f, 1.5f)
            secondaryScale = (o.optInt("secondaryScale", 100) / 100f).coerceIn(0.1f, 1.5f)
            showTranslation = o.optBoolean("showTranslation", true)
            showRomanization = o.optBoolean("showRomanization", false)
            showBackground = o.optBoolean("showBackground", true)
            showNextLine = o.optBoolean("showNextLine", false)
            hideWhenPaused = o.optBoolean("hideWhenPaused", false)
            hideInLandscape = o.optBoolean("hideInLandscape", false)
            widthPercent = o.optInt("widthPercent", 92).coerceIn(40, 100)
            useLyricFont = o.optBoolean("useLyricFont", false)
            lyricFontPath = o.optString("lyricFontPath", "")
            locked = o.optBoolean("locked", false)
            xPos = o.optInt("x", 0)
            yPos = o.optInt("y", 96)
        }
    }

    private fun applySettings(revealControls: Boolean) {
        if (!canDrawOverlay()) {
            stopSelf()
            return
        }
        if (rootView == null) addOverlay()
        lyricView?.applyPreferences(
            textColor,
            unplayedColor,
            opacity,
            fontScale,
            secondaryScale,
            showTranslation,
            showRomanization,
            showBackground,
            showNextLine,
        )
        lyricView?.applyFont(
            if (useLyricFont) lyricFontPath else ""
        )
        lyricView?.setLyrics(parseLyrics(lyricsJson))
        lyricView?.setPlayback(positionMs, playing)
        updateWindowLayout()
        setLocked(locked, revealControls)
        updateVisibility()
    }

    private fun updateWindowLayout() {
        val root = rootView ?: return
        val params = layoutParams ?: return
        lyricView?.layoutParams = lyricView?.layoutParams?.apply {
            width = overlayWidth()
            height = overlayHeight()
        }
        params.x = xPos
        params.y = yPos
        clampToScreen(root, params)
        runCatching { windowManager.updateViewLayout(root, params) }
    }

    private fun updateVisibility(playingOverride: Boolean? = null) {
        val root = rootView ?: return
        // 窗口刚建好、播放态还没到：先不显示。否则冷启动（歌曲恢复为暂停态、
        // 且用户勾了「暂停时隐藏」）会先按默认值闪一个空面板出来。
        if (!playbackSynced) {
            root.visibility = View.GONE
            return
        }
        val isPlaying = playingOverride ?: playing
        val hidden = (hideWhenPaused && !isPlaying) ||
            (
                hideInLandscape &&
                    resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE
                )
        root.visibility = if (hidden) View.GONE else View.VISIBLE
    }

    private fun setLocked(lock: Boolean, revealControls: Boolean = true) {
        val params = layoutParams ?: return
        params.flags = if (lock) {
            params.flags or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
        } else {
            params.flags and WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE.inv()
        }
        if (lock) {
            // 真正锁定时收起面板（背景+控件），并屏蔽触摸
            rootView?.removeCallbacks(hideControlsRunnable)
            controlsView?.visibility = View.GONE
            lockRowView?.visibility = View.GONE
            hideBackgroundPanel()
        } else if (revealControls) {
            // 解锁动作：整体唤出控制面板
            showControlsWithAnimation()
        }
        // 注意：日常 applySettings(revealControls=false) 走到这里不会改变控制条可见性，
        // 避免把用户已唤出的控件在歌词进度/设置同步时又被强制隐藏。
        rootView?.let { runCatching { windowManager.updateViewLayout(it, params) } }
        if (lock) postUnlockNotification() else notificationManager.cancel(NOTIFICATION_ID)
    }

    // ---- 拖拽 / 点按 ----

    private fun onDrag(view: View, event: MotionEvent): Boolean {
        if (locked) return false
        val params = layoutParams ?: return false
        val root = rootView ?: view
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downX = event.rawX
                downY = event.rawY
                startX = params.x
                startY = params.y
                movedDuringTouch = false
                longPressTriggered = false
                root.removeCallbacks(longPressRunnable)
                root.postDelayed(longPressRunnable, LONG_PRESS_TIMEOUT_MS)
            }
            MotionEvent.ACTION_MOVE -> {
                val dx = event.rawX - downX
                val dy = event.rawY - downY
                // 超过拖动阈值才判定为拖拽；否则视为点击中的轻微抖动，不移动窗口、不吞掉单击。
                if (!movedDuringTouch &&
                    (abs(dx) > dp(DRAG_THRESHOLD_DP) || abs(dy) > dp(DRAG_THRESHOLD_DP))
                ) {
                    movedDuringTouch = true
                    root.removeCallbacks(longPressRunnable)
                }
                if (movedDuringTouch) {
                    // 拖拽中整体面板常显（背景+控制条），不排自动隐藏。
                    showControlsWithAnimation(scheduleHide = false)
                    params.x = startX + dx.roundToInt()
                    params.y = startY + dy.roundToInt()
                    clampToScreen(root, params)
                    windowManager.updateViewLayout(root, params)
                }
            }
            MotionEvent.ACTION_UP -> {
                root.removeCallbacks(longPressRunnable)
                xPos = params.x
                yPos = params.y
                persistPosition(xPos, yPos)
                emitEvent("onPositionChanged", mapOf("x" to xPos, "y" to yPos))
                when {
                    movedDuringTouch -> showControlsWithAnimation() // 拖拽结束：保持整块 N 秒后收起
                    !longPressTriggered -> handleTap()              // 单击：整体切换（背景+控制条一起）
                    else -> showControlsWithAnimation()             // 长按已唤出：保持 N 秒
                }
            }
            MotionEvent.ACTION_CANCEL -> {
                root.removeCallbacks(longPressRunnable)
                showControlsWithAnimation()
            }
        }
        return true
    }

    private fun handleTap() {
        if ((rootBg?.alpha ?: 0) > 0) {
            // 面板已显示，单击整体收起
            hideBackgroundPanel()
        } else {
            // 面板隐藏，单击整体唤出（背景+控制条）
            showControlsWithAnimation()
        }
    }

    private fun scheduleControlsAutoHide() {
        rootView?.removeCallbacks(hideControlsRunnable)
        rootView?.postDelayed(hideControlsRunnable, CONTROLS_AUTO_HIDE_MS)
    }

    /** 整体唤出：背景底板与控制条作为同一块面板，一起淡入。
     *  scheduleHide=true 时排 N 秒后整体隐藏；false 表示按住/拖拽中常显，由调用方决定何时隐藏。 */
    private fun showControlsWithAnimation(scheduleHide: Boolean = true) {
        if (locked) return
        controlsView.showAsControls()
        lockRowView.showAsControls()
        showBackgroundPanel(scheduleHide)
        if (scheduleHide) scheduleControlsAutoHide()
    }

    /** 控制行（底部三键 + 顶部锁定）同步整体显现。 */
    private fun View?.showAsControls() {
        this?.apply {
            visibility = View.VISIBLE
            alpha = 1f
            scaleX = 1f
            scaleY = 1f
        }
    }

    /**
     * 底板淡入。scheduleHide=true 时重置自动隐藏计时（无操作 3 秒淡出）；
     * false 表示按住/拖拽中保持常显，抬起（ACTION_UP）时再排隐藏。
     */
    private fun showBackgroundPanel(scheduleHide: Boolean = true) {
        val bg = rootBg ?: return
        val root = rootView ?: return
        root.removeCallbacks(hideBgRunnable)
        bgAnimator?.cancel()
        bgAnimator = ValueAnimator.ofInt(bg.alpha, 255).apply {
            duration = 180
            addUpdateListener { bg.alpha = it.animatedValue as Int }
            start()
        }
        if (scheduleHide) root.postDelayed(hideBgRunnable, BACKGROUND_AUTO_HIDE_MS)
    }

    /** 底板自动淡出（回到纯歌词浮字状态），并同步收起控制条。 */
    private fun hideBackgroundPanel() {
        rootView?.removeCallbacks(hideControlsRunnable)
        if (!locked && controlsView?.visibility == View.VISIBLE) hideControls()
        val bg = rootBg ?: return
        bgAnimator?.cancel()
        bgAnimator = ValueAnimator.ofInt(bg.alpha, 0).apply {
            duration = 260
            addUpdateListener { bg.alpha = it.animatedValue as Int }
            start()
        }
    }

    private fun hideControls() {
        if (!locked) {
            controlsView.animateControlsHide()
            lockRowView.animateControlsHide()
        }
    }

    /** 控制行同步缩小淡出，结束后复位待下次唤出。 */
    private fun View?.animateControlsHide() {
        this?.apply {
            animate().cancel()
            animate()
                .alpha(0f)
                .scaleX(CONTROL_HIDDEN_SCALE)
                .scaleY(CONTROL_HIDDEN_SCALE)
                .setDuration(CONTROL_ANIMATION_MS)
                .withEndAction {
                    visibility = View.GONE
                    alpha = 1f
                    scaleX = 1f
                    scaleY = 1f
                }
                .start()
        }
    }

    private fun clampToScreen(view: View, params: WindowManager.LayoutParams) {
        val width = view.width.takeIf { it > 0 } ?: overlayWidth()
        val height = view.height.takeIf { it > 0 } ?: overlayHeight()
        val maxX = (resources.displayMetrics.widthPixels / 2 - width / 2).coerceAtLeast(0)
        val maxY = (resources.displayMetrics.heightPixels - height).coerceAtLeast(0)
        params.x = params.x.coerceIn(-maxX, maxX)
        params.y = params.y.coerceIn(-statusBarHeight(), maxY)
    }

    private fun overlayWidth(): Int {
        return (resources.displayMetrics.widthPixels * widthPercent / 100f)
            .roundToInt()
            .coerceIn(dp(180), resources.displayMetrics.widthPixels - dp(12))
    }

    /** 浮窗高度跟随字号：原来是死值 150dp，用户调大字号后文本框不会跟着长，
     *  观感就是「设置的高度没生效」。 */
    private fun overlayHeight(): Int =
        (dp(150) * fontScale.coerceIn(0.7f, 1.5f)).roundToInt()

    private fun statusBarHeight(): Int {
        val id = resources.getIdentifier("status_bar_height", "dimen", "android")
        return if (id > 0) resources.getDimensionPixelSize(id) else dp(24)
    }

    // ---- 锁定通知 ----

    private fun postUnlockNotification() {
        ensureNotificationChannel()
        val unlockIntent = PendingIntent.getService(
            this,
            0,
            Intent(this, LyricsOverlayService::class.java).setAction(ACTION_UNLOCK),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        runCatching {
            notificationManager.notify(
                NOTIFICATION_ID,
                builder
                    .setSmallIcon(R.drawable.ic_notification)
                    .setContentTitle("桌面歌词已锁定")
                    .setContentText("点击解锁后可拖动位置")
                    .setContentIntent(unlockIntent)
                    .setOngoing(true)
                    .setShowWhen(false)
                    .build()
            )
        }
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        if (notificationManager.getNotificationChannel(CHANNEL_ID) != null) return
        notificationManager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "桌面歌词",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                setSound(null, null)
                enableVibration(false)
                setShowBadge(false)
            }
        )
    }

    private fun disableAndStop() {
        rootView?.let { runCatching { windowManager.removeView(it) } }
        rootView = null
        lyricView = null
        controlsView = null
        playPauseButton = null
        layoutParams = null
        notificationManager.cancel(NOTIFICATION_ID)
        stopSelf()
    }

    private fun canDrawOverlay(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(this)

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).roundToInt()

    // ---- 歌词解析 ----

    private fun parseLyrics(json: String): List<LyricLineData> {
        if (json.isBlank()) return emptyList()
        return runCatching {
            val root = JSONObject(json)
            val arr = root.optJSONArray("lines") ?: return emptyList()
            val result = ArrayList<LyricLineData>(arr.length())
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                val words = ArrayList<LyricWordData>()
                val wordsArr = o.optJSONArray("words")
                if (wordsArr != null) {
                    for (j in 0 until wordsArr.length()) {
                        val w = wordsArr.optJSONObject(j) ?: continue
                        words.add(
                            LyricWordData(
                                text = w.optString("text", ""),
                                startMs = (w.optDouble("start", 0.0) * 1000).toLong(),
                                endMs = (w.optDouble("end", 0.0) * 1000).toLong(),
                            )
                        )
                    }
                }
                val secondary = ArrayList<String>()
                val secArr = o.optJSONArray("secondary")
                if (secArr != null) {
                    for (j in 0 until secArr.length()) {
                        secArr.optString(j).takeIf { it.isNotBlank() }?.let { secondary.add(it) }
                    }
                }
                result.add(
                    LyricLineData(
                        startMs = o.optLong("startMs", 0L),
                        endMs = o.optLong("endMs", 0L),
                        text = o.optString("text", ""),
                        translation = o.optString("translation", "").takeIf { it.isNotBlank() },
                        romaji = o.optString("romaji", "").takeIf { it.isNotBlank() },
                        words = words,
                        secondary = secondary,
                    )
                )
            }
            result
        }.getOrElse { emptyList() }
    }

    companion object {
        const val ACTION_ENABLE = "com.example.xianyu.action.ENABLE_FLOATING_LYRIC"
        const val ACTION_HIDE = "com.example.xianyu.action.HIDE_FLOATING_LYRIC"
        const val ACTION_UNLOCK = "com.example.xianyu.action.UNLOCK_FLOATING_LYRIC"
        const val CHANNEL = "xianyu/floating_lyrics"
        const val EVENTS_CHANNEL = "xianyu/floating_lyrics_events"

        private const val CHANNEL_ID = "xianyu_floating_lyric"
        private const val NOTIFICATION_ID = 0x52444C59
        private const val CONTROLS_AUTO_HIDE_MS = 4_000L
        private const val BACKGROUND_AUTO_HIDE_MS = 3_000L
        private const val LYRICS_REQUEST_INTERVAL_MS = 3_000L
        private const val MAX_LYRICS_REQUESTS = 4
        private const val LONG_PRESS_TIMEOUT_MS = 460L
        private const val DRAG_THRESHOLD_DP = 8
        private const val CONTROL_ANIMATION_MS = 220L
        private const val CONTROL_HIDDEN_SCALE = 0.8f

        private const val TAG = "LyricsOverlay"
        private const val PREFS_NAME = "xianyu_floating_lyrics"
        private const val KEY_SETTINGS = "settingsJson"

        // Flutter 的推送可能早于服务创建（startService 是异步的，实例此时为 null），
        // 旧实现 `instance?.setSettings()` 会把这些推送静默丢掉，窗口就只能拿
        // 内存里的默认值建出来——字号变小、宽度变窄、位置回到顶部。这里统一缓冲：
        // 服务一起来先用缓冲/本地值把字段填好，再按需补推。
        @Volatile
        private var pendingSettings: String? = null

        @Volatile
        private var pendingLyrics: String? = null

        @Volatile
        private var pendingPlayback: Pair<Long, Boolean>? = null

        @Volatile
        private var pendingLocked: Boolean? = null

        fun pushSettings(context: Context, json: String) {
            if (json.isBlank()) return
            pendingSettings = json
            runCatching {
                context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                    .edit()
                    .putString(KEY_SETTINGS, json)
                    .apply()
            }
            instance?.setSettings(json)
        }

        fun pushLyrics(json: String) {
            pendingLyrics = json
            instance?.setLyrics(json)
        }

        fun pushPlayback(posMs: Long, isPlaying: Boolean) {
            pendingPlayback = posMs to isPlaying
            instance?.setPlayback(posMs, isPlaying)
        }

        fun pushLocked(lock: Boolean) {
            pendingLocked = lock
            instance?.setLocked(lock)
        }

        fun pushResetPosition() {
            instance?.resetPosition()
        }

        @Volatile
        var instance: LyricsOverlayService? = null

        fun canDraw(context: Context): Boolean =
            Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(context)

        fun permissionIntent(context: Context): Intent =
            Intent(
                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                Uri.parse("package:${context.packageName}")
            )

        fun show(context: Context) {
            runCatching {
                context.startService(Intent(context, LyricsOverlayService::class.java).setAction(ACTION_ENABLE))
            }
        }

        fun hide(context: Context) {
            runCatching {
                context.startService(Intent(context, LyricsOverlayService::class.java).setAction(ACTION_HIDE))
            }
        }
    }
}

/** 持有 Flutter 引擎 messenger，供服务创建事件通道回调 Flutter。 */
object FlutterMessengerHolder {
    @Volatile
    var messenger: BinaryMessenger? = null
}
