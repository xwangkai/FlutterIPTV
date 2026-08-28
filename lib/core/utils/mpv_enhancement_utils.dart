import 'dart:async';
import 'dart:io';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import '../services/service_locator.dart';
import '../../features/settings/providers/settings_provider.dart';

/// 共享的 mpv 画质增强工具集。
///
/// 提取自 PlayerProvider 和 MultiScreenProvider 的重复代码，包括：
/// - FSR 1.0 RCAS 着色器
/// - 安全的 setProperty / getProperty 封装
/// - 滤镜链验证
/// - deband / 缩放算法 / FSR 锐化 应用
///
/// 用法：所有方法均为静态方法，接收 Player 实例作为参数。
class MpvEnhancementUtils {
  MpvEnhancementUtils._(); // 禁止实例化

  // ═══════════════════════════════════════════════════════════════════
  // FSR 1.0 RCAS 着色器（Robust Contrast Adaptive Sharpening）
  // ═══════════════════════════════════════════════════════════════════

  static const String fsrRcasGlsl = r'''
//!HOOK SCALED
//!BIND HOOKED
//!DESC AMD FidelityFX Super Resolution 1.0 (RCAS)

#define FSR_RCAS_LIMIT 0.25

vec4 hook() {
    vec4 b = HOOKED_texOff(vec2( 0.0, -1.0));
    vec4 d = HOOKED_texOff(vec2(-1.0,  0.0));
    vec4 e = HOOKED_texOff(vec2( 0.0,  0.0));
    vec4 f = HOOKED_texOff(vec2( 1.0,  0.0));
    vec4 h = HOOKED_texOff(vec2( 0.0,  1.0));

    const vec3 lw = vec3(0.2126, 0.7152, 0.0722);
    float bL = dot(b.rgb, lw), dL = dot(d.rgb, lw);
    float eL = dot(e.rgb, lw), fL = dot(f.rgb, lw), hL = dot(h.rgb, lw);

    float mn4L = min(min(bL, dL), min(fL, hL));
    float mx4L = max(max(bL, dL), max(fL, hL));

    float ampL = sqrt(clamp(min(mn4L, 1.0 - mx4L) / (mx4L + 1e-6), 0.0, 1.0));
    float wL   = -clamp(ampL / 8.0, 0.0, FSR_RCAS_LIMIT) * exp2(-FSR_RCAS_LIMIT);

    float rcpL = 1.0 / (4.0 * wL + 1.0);
    vec3 result = clamp(((b.rgb + d.rgb + f.rgb + h.rgb) * wL + e.rgb) * rcpL, 0.0, 1.0);
    return vec4(result, e.a);
}
''';

  // 缓存 FSR 着色器临时路径
  static String? _fsrShaderPath;

  // ═══════════════════════════════════════════════════════════════════
  // 安全的 mpv 属性读写
  // ═══════════════════════════════════════════════════════════════════

  /// 安全调用 setProperty，单个失败不影响其他调用。
  /// 返回 true 表示成功，false 表示失败。
  static Future<bool> safeSetProperty(
      Player player, String property, String value, String label) async {
    try {
      final nativePlayer = player.platform as dynamic;
      await nativePlayer.setProperty(property, value);
      return true;
    } catch (e) {
      ServiceLocator.log.d('MpvUtils: 设置 $label 失败: $e');
      return false;
    }
  }

  /// 安全读取 getProperty，失败返回 null。
  static Future<String?> safeGetProperty(
      Player player, String property, String label) async {
    try {
      final nativePlayer = player.platform as dynamic;
      return await nativePlayer.getProperty(property);
    } catch (e) {
      ServiceLocator.log.d('MpvUtils: 读取 $label 失败: $e');
      return null;
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  // 滤镜链验证
  // ═══════════════════════════════════════════════════════════════════

  /// 验证滤镜链/去交错是否真正生效。
  ///
  /// mpv 设置 vf 或 deinterlace 后是异步重建滤镜链，失败时可能通过 log 或
  /// error 流报告。同时监听两个流，350ms 内无失败信号则视为生效。
  static Future<bool> verifyFilterChainActive(Player player, String label) async {
    final failureSignaled = Completer<bool>();

    void checkFailure(String msg) {
      if (msg.contains('Disabling filter') ||
          msg.contains('Impossible to convert') ||
          msg.contains('failed to configure the filter graph') ||
          msg.contains('no such filter') ||
          msg.contains('error creating filters') ||
          msg.contains('Error parsing option') ||
          msg.contains('option not found')) {
        if (!failureSignaled.isCompleted) failureSignaled.complete(true);
      }
    }

    final logSub = player.stream.log.listen((log) => checkFailure(log.text));
    final errSub = player.stream.error.listen((err) {
      if (err.isNotEmpty) checkFailure(err);
    });

    final failed = await failureSignaled.future.timeout(
      const Duration(milliseconds: 350),
      onTimeout: () => false,
    );
    await logSub.cancel();
    await errSub.cancel();
    if (failed) {
      ServiceLocator.log.d('MpvUtils: 滤镜链验证失败($label): 检测到 mpv 滤镜配置错误');
    }
    return !failed;
  }

  // ═══════════════════════════════════════════════════════════════════
  // FSR 着色器文件管理
  // ═══════════════════════════════════════════════════════════════════

  /// 确保 FSR RCAS GLSL 着色器文件已写入临时目录，返回其路径。
  static Future<String?> ensureFsrShader() async {
    if (_fsrShaderPath != null && await File(_fsrShaderPath!).exists()) {
      return _fsrShaderPath;
    }
    _fsrShaderPath = null;
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/fsr_rcas.glsl');
      await file.writeAsString(fsrRcasGlsl, flush: true);
      _fsrShaderPath = file.path;
      ServiceLocator.log.d('MpvUtils: FSR shader written to $_fsrShaderPath');
      return _fsrShaderPath;
    } catch (e) {
      ServiceLocator.log.d('MpvUtils: Failed to write FSR shader: $e');
      return null;
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  // 画质增强应用（deband / 缩放算法 / FSR RCAS）
  // ═══════════════════════════════════════════════════════════════════

  /// 根据设置项应用画质增强（deband、缩放算法、FSR RCAS）。
  ///
  /// [isAndroidTV] 参数允许调用方覆盖 Android TV 检测。
  /// - 多屏场景：强制软解 vo=libmpv，deband/FSR 无效，应传 `true`
  /// - 单屏增强播放器：vo 可能为 gpu，deband/FSR 可生效，不传或传 `false`
  static Future<void> applyEnhancementSettings(
    Player player, {
    bool isAndroidTV = false,
  }) async {
    final settings = ServiceLocator.settings;
    if (settings == null) return;

    final isTV = isAndroidTV;

    // --- Deband （Android TV 无效，跳过）---
    if (!isTV) {
      final debandEnabled = settings.videoDebandEnabled;
      if (debandEnabled) {
        await safeSetProperty(player, 'deband', 'yes', 'deband');
        await safeSetProperty(player, 'deband-iterations', '4', 'deband-iterations');
        await safeSetProperty(player, 'deband-threshold', '48', 'deband-threshold');
        await safeSetProperty(player, 'deband-range', '16', 'deband-range');
      } else {
        await safeSetProperty(player, 'deband', 'no', 'deband');
      }
    }

    // --- Scale algorithm ---
    // Android TV 软解时 ewa_lanczos 极耗 CPU，自动降级为 spline36
    final scaleMode = settings.videoScaleMode;
    final effectiveScale =
        (scaleMode == 'ewa_lanczos' && isTV) ? 'spline36' : scaleMode;
    if (effectiveScale == 'ewa_lanczos') {
      await safeSetProperty(player, 'scale', 'ewa_lanczos', 'scale');
    } else if (effectiveScale == 'spline36') {
      await safeSetProperty(player, 'scale', 'spline36', 'scale');
    } else {
      await safeSetProperty(player, 'scale', 'bilinear', 'scale');
    }

    // --- FSR 1 RCAS sharpening （Android TV 无效，跳过）---
    if (!isTV) {
      final fsrEnabled = settings.videoFsrEnabled;
      if (fsrEnabled) {
        final shaderPath = await ensureFsrShader();
        if (shaderPath != null) {
          await safeSetProperty(player, 'glsl-shaders', shaderPath, 'glsl-shaders-fsr');
        }
      } else {
        await safeSetProperty(player, 'glsl-shaders', '', 'glsl-shaders-clear');
      }
    }
  }
}