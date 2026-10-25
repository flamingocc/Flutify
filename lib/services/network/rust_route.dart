import 'network_proxy.dart';
import 'proxy_endpoint.dart';
import 'proxy_mode.dart';

/// Rust 网络栈（HTTP/2、音频下载、WebSocket）对 [url] 应走的路线：
/// - `null`：交给 Dart 网络层（网关会改写地址、加网关头，只在 Dart 侧实现）；
/// - `''`：直连；
/// - 其他：代理地址 `http://[user:pass@]host:port` / `socks5h://…`。
///
/// 选路（系统代理、PAC 求值、手动代理、绕过列表）仍由 [NetworkProxy] 完成，Rust 只按结果连接。
Future<String?> rustRouteFor(Uri url, {NetworkProxy? proxy}) async {
  final p = proxy ?? NetworkProxy.instance;
  try {
    if (p.gateway.route(url) != url) return null;
  } on FormatException {
    return null;
  }
  final endpoint = await p.endpointForAsync(url);
  if (endpoint == null) return '';
  final scheme = endpoint.type == ProxyType.socks5 ? 'socks5h' : 'http';
  final host = endpoint.host.contains(':') ? '[${endpoint.host}]' : endpoint.host;
  // 只有手动代理带认证信息（系统代理 / PAC 不提供用户名密码）
  var auth = '';
  if (p.mode == ProxyMode.manual && p.manualHasCredentials) {
    auth =
        '${Uri.encodeComponent(p.manualUsername)}:${Uri.encodeComponent(p.manualPassword)}@';
  }
  return '$scheme://$auth$host:${endpoint.port}';
}
