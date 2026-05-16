class HdcDevice {
  final String serial;
  final String state;        // Connected / Offline ...
  final String connection;   // USB / TCP
  final String name;         // device name from hdc -v, empty if unknown

  const HdcDevice({
    required this.serial,
    required this.state,
    required this.connection,
    this.name = '',
  });

  bool get isOnline => state.toLowerCase().contains('connect');

  String get displayName {
    final connLabel = connection == 'TCP' ? 'WiFi' : connection;
    if (name.isNotEmpty) return '[$name]$serial（$connLabel）';
    return '$serial（$connLabel）';
  }

  @override
  bool operator ==(Object other) =>
      other is HdcDevice && other.serial == serial;

  @override
  int get hashCode => serial.hashCode;
}
