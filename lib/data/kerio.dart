class KerioBalance {
  const KerioBalance(this.total, this.remaining);
    
  final int total;
  final int remaining;

  /// No balance to show (Kerio isn't set up or can't be reached): "--".
  static const none = KerioBalance(0, 0);
}