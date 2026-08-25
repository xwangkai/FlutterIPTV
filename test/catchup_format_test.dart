import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:flutter_iptv/core/models/channel.dart';
import 'package:flutter_iptv/core/services/epg_service.dart';
import 'package:flutter_iptv/core/utils/catchup_url_builder.dart';

/// 验证共享的 buildCatchupUrl（Flutter 播放器与 Android TV 原生回放共用）
/// 中占位符替换逻辑的正确性（Step 1/2/2.4/2.5/2.6/3）。
void main() {
  // 使用固定时间模拟 EPG 节目（本地时间）
  final startLocal = DateTime(2024, 1, 1, 12, 0, 0); // 本地 12:00
  final endLocal = DateTime(2024, 1, 1, 12, 30, 0); // 本地 12:30
  final startUtc = startLocal.toUtc();
  final endUtc = endLocal.toUtc();

  final startIso = startUtc.toIso8601String();
  final startIsoClean = startIso.replaceAll(RegExp(r'\.\d+Z$'), 'Z');
  final endIso = endUtc.toIso8601String();
  final endIsoClean = endIso.replaceAll(RegExp(r'\.\d+Z$'), 'Z');

  final startSec = startUtc.millisecondsSinceEpoch ~/ 1000;
  final endSec = endUtc.millisecondsSinceEpoch ~/ 1000;
  final durationSec = endUtc.difference(startUtc).inSeconds;

  // 当前时刻（UTC）— 对齐 rtp2httpd 的 ${lutc}/${now}/${timestamp}/${offset}
  final now = DateTime.now().toUtc();
  final nowSec = now.millisecondsSinceEpoch ~/ 1000;
  final nowIso = now.toIso8601String().replaceAll(RegExp(r'\.\d+Z$'), 'Z');
  final offsetSec = nowSec - startSec;

  final program = EpgProgram(
    channelId: 'test',
    title: 'Program',
    start: startLocal,
    end: endLocal,
  );

  Channel channelWith(String? catchupSource, {String? catchupMode}) => Channel(
        playlistId: 1,
        name: 'Test Channel',
        url: 'http://example.com/live.m3u8',
        catchup: catchupMode,
        catchupSource: catchupSource,
      );

  String build(String source, {String? mode}) {
    final url = buildCatchupUrl(channelWith(source, catchupMode: mode), program);
    expect(url, isNotNull, reason: 'catchupSource 已设置，应能生成 URL');
    return url!;
  }

  test('无 catchup-source 返回 null', () {
    expect(buildCatchupUrl(channelWith(null), program), isNull);
  });

  test('utc/utcend 输出 Unix 秒', () {
    expect(build('?start=\${utc}&end=\${utcend}'), '?start=$startSec&end=$endSec');
  });

  test('utc 与 utcend 大括号版本', () {
    expect(build('{utc}-{utcend}'), '$startSec-$endSec');
  });

  test('duration 输出秒数', () {
    expect(build('?dur=\${duration}'), '?dur=$durationSec');
  });

  test('timestamp 输出当前时刻 Unix 秒（对齐 rtp2httpd）', () {
    expect(build('?ts=\${timestamp}'), '?ts=$nowSec');
  });

  test('lutc/now 输出当前时刻完整 ISO+Z（对齐 rtp2httpd）', () {
    expect(build('?a=\${lutc}&b=\${now}&c={now}'), '?a=$nowIso&b=$nowIso&c=$nowIso');
  });

  test('offset 输出现时刻与开始时刻差（秒）', () {
    expect(build('?o=\${offset}'), '?o=$offsetSec');
  });

  test('utc:格式 用格式串渲染开始时间 UTC', () {
    final expected = DateFormat('yyyyMMddHHmmss').format(startUtc);
    expect(build('?start=\${utc:yyyyMMddHHmmss}'), '?start=$expected');
  });

  test('utcend:格式 用格式串渲染结束时间 UTC', () {
    final expected = DateFormat('yyyyMMdd').format(endUtc);
    expect(build('?end=\${utcend:yyyyMMdd}'), '?end=$expected');
  });

  test('关键字:格式 大括号版本', () {
    final expectedS = DateFormat('HH').format(startUtc);
    final expectedE = DateFormat('HH').format(endUtc);
    expect(build('?s={utc:HH}&e={utcend:HH}'), '?s=$expectedS&e=$expectedE');
  });

  test('时间分量占位符（长格式）取开始时间 UTC', () {
    expect(
      build('?y=\${yyyy}&m=\${MM}&d=\${dd}'),
      '?y=${DateFormat('yyyy').format(startUtc)}'
          '&m=${DateFormat('MM').format(startUtc)}'
          '&d=${DateFormat('dd').format(startUtc)}',
    );
  });

  test('时间分量占位符（短格式）取开始时间 UTC', () {
    expect(
      build('?H={H}&M={M}&S={S}'),
      '?H=${DateFormat('HH').format(startUtc)}'
          '&M=${DateFormat('mm').format(startUtc)}'
          '&S=${DateFormat('ss').format(startUtc)}',
    );
  });

  test('(b)yyyyMMddHHmmss:UTC 后缀 UTC', () {
    final expected = DateFormat('yyyyMMddHHmmss').format(startUtc);
    expect(build('&Playseek=\${(b)yyyyMMddHHmmss:UTC}'), '&Playseek=$expected');
  });

  test('(bu)yyyyMMddHHmmss 前缀 u', () {
    final expected = DateFormat('yyyyMMddHHmmss').format(startUtc);
    expect(build('&Playseek=\${(bu)yyyyMMddHHmmss}'), '&Playseek=$expected');
  });

  test('(b)yyyyMMddHHmmss 无时区 -> 本地时间', () {
    final expected = DateFormat('yyyyMMddHHmmss').format(startLocal);
    expect(build('&Playseek=\${(b)yyyyMMddHHmmss}'), '&Playseek=$expected');
  });

  test('start/end ISO UTC', () {
    expect(
      build('?start=\${start}&end=\${end}'),
      '?start=$startIsoClean&end=$endIsoClean',
    );
  });

  test('混合：标准 + 自定义格式', () {
    final expectedPs = DateFormat('yyyyMMddHHmmss').format(startUtc);
    expect(
      build('?starttime=\${utc}&endtime=\${utcend}&ps=\${(b)yyyyMMddHHmmss:UTC}'),
      '?starttime=$startSec&endtime=$endSec&ps=$expectedPs',
    );
  });

  test('append 模式：在直播地址末尾追加模板', () {
    // append 模式返回 channel.url + 替换后的模板
    expect(
      build('&starttime={utc}&endtime={utcend}', mode: 'append'),
      'http://example.com/live.m3u8&starttime=$startSec&endtime=$endSec',
    );
  });
}
