package com.flutify.music.flutify_app

import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine

// audio_service 要求：Activity 与后台媒体服务共用同一个 Flutter 引擎（通知栏 / 锁屏控件）
class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Android 原生 DRM 播放引擎（该机型 WebView EME 不可用，走 ExoPlayer + MediaDrm）
        NativeDrmPlugin.register(flutterEngine, this)
        UpdatePlugin.register(flutterEngine, this)
        // 歌词外显：Flyme 状态栏歌词、蓝牙（车机）媒体信息换歌词
        LyricBridgePlugin.register(flutterEngine, this)
        if (!flutterEngine.plugins.has(AppleMusicBackgroundPlugin::class.java)) {
            flutterEngine.plugins.add(AppleMusicBackgroundPlugin())
        }
    }
}
