import 'dart:ffi';

const _internetOptionRefresh = 37;
const _internetOptionSettingsChanged = 39;

/// Tells WinINet (and so browsers and most apps) to re-read the proxy
/// settings just written to the registry; without this they keep the old
/// ones until restarted.
void notifyWinInetProxyChanged() {
  final wininet = DynamicLibrary.open('wininet.dll');
  final setOption = wininet.lookupFunction<Int32 Function(Pointer<Void>, Uint32, Pointer<Void>, Uint32),
      int Function(Pointer<Void>, int, Pointer<Void>, int)>('InternetSetOptionW');
  setOption(nullptr, _internetOptionSettingsChanged, nullptr, 0);
  setOption(nullptr, _internetOptionRefresh, nullptr, 0);
}
