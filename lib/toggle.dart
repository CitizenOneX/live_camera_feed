class ToggleMsg {
  /// basic on/off toggle message that can be used for any specified msg type
  static List<int> pack(int msgType, bool isOn) {
    return [0x01, msgType & 0xFF, 0, 1, isOn ? 1 : 0];
  }
}