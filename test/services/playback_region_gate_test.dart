import 'package:flutify_app/services/auth/login_region_check.dart';
import 'package:flutify_app/services/playback/playback_region_gate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(LoginRegionCheck.resetForTest);
  tearDown(LoginRegionCheck.resetForTest);

  test('出口在中国大陆时拦下，其他地区放行', () async {
    var probeCalls = 0;
    String code = 'CN';
    final gate = PlaybackRegionGate(
      probe: () async {
        probeCalls++;
        return LoginRegion(code);
      },
    );

    final blocked = await gate.ensureAllowed();
    expect(blocked?.code, 'CN');
    expect(gate.isBlocked, isTrue);

    // 同一次运行里后续起播直接用缓存，不再开一次无头 WebView
    expect(await gate.ensureAllowed(), isNotNull);
    expect(probeCalls, 1);

    code = 'JP';
    gate.markNetworkChanged();
    expect(await gate.ensureAllowed(), isNull);
    expect(gate.isBlocked, isFalse);
    expect(probeCalls, 2);
  });

  test('检测不到出口（网络不通 / 测试环境）不拦播放', () async {
    final gate = PlaybackRegionGate(
      probe: () async => const LoginRegion.unknown(),
    );
    expect(await gate.ensureAllowed(), isNull);
    expect(gate.isBlocked, isFalse);
  });

  test('并发起播只跑一次检测', () async {
    var probeCalls = 0;
    final gate = PlaybackRegionGate(
      probe: () async {
        probeCalls++;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return const LoginRegion('CN');
      },
    );

    final results = await Future.wait([
      gate.ensureAllowed(),
      gate.ensureAllowed(),
    ]);
    expect(probeCalls, 1);
    expect(results.every((r) => r?.code == 'CN'), isTrue);
  });

  test('设置里关掉检测：连探针都不调用', () async {
    var probeCalls = 0;
    final gate = PlaybackRegionGate(
      enabled: () => false,
      probe: () async {
        probeCalls++;
        return const LoginRegion('CN');
      },
    );

    expect(await gate.ensureAllowed(), isNull);
    expect(probeCalls, 0);
  });

  test('本次打开跳过：登录页和播放侧共用同一个标记', () async {
    var probeCalls = 0;
    final gate = PlaybackRegionGate(
      probe: () async {
        probeCalls++;
        return const LoginRegion('CN');
      },
    );

    expect(LoginRegionCheck.skippedThisRun, isFalse);
    expect(await gate.ensureAllowed(), isNotNull, reason: '没跳过时照常检测');

    expect(LoginRegionCheck.skipForThisRun(), isTrue);
    expect(LoginRegionCheck.skipForThisRun(), isFalse, reason: '只记第一次');

    // 跳过期间不再检测：探针一次都不多跑
    expect(await gate.ensureAllowed(), isNull);
    expect(probeCalls, 1);

    // 重启后恢复检测（内存标记归零）：下一次起播重新探一次
    LoginRegionCheck.resetForTest();
    gate.markNetworkChanged();
    expect(await gate.ensureAllowed(), isNotNull);
    expect(probeCalls, 2);
  });

  test('检测抛异常按未知处理，不影响播放', () async {
    final gate = PlaybackRegionGate(
      probe: () async => throw StateError('probe broke'),
    );
    // 异常交给调用方（PlaybackProvider 的 try/catch）收进「未知」
    await expectLater(gate.ensureAllowed(), throwsStateError);
  });

  test('关闭网络变动自动复查时，markNetworkChanged 保留上次检测结果', () async {
    var probeCalls = 0;
    var recheck = false;
    var code = 'SG';
    final gate = PlaybackRegionGate(
      recheckOnNetworkChange: () => recheck,
      probe: () async {
        probeCalls++;
        return LoginRegion(code);
      },
    );

    expect(await gate.ensureAllowed(), isNull);
    expect(probeCalls, 1);

    code = 'CN';
    gate.markNetworkChanged();
    expect(await gate.ensureAllowed(), isNull, reason: '未开启网络变动复查，沿用上次结果');
    expect(probeCalls, 1);

    recheck = true;
    gate.markNetworkChanged();
    expect((await gate.ensureAllowed())?.code, 'CN');
    expect(probeCalls, 2);
  });
}
