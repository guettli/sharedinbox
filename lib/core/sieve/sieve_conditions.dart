sealed class SieveCondition {}

final class HeaderCondition extends SieveCondition {
  HeaderCondition(this.headers, this.matchType, this.keyList);
  final List<String> headers;
  final String matchType; // ':contains', ':is', ':matches'
  final List<String> keyList;
}

final class SizeCondition extends SieveCondition {
  SizeCondition(this.comparison, this.bytes);
  final String comparison; // ':over' or ':under'
  final int bytes;
}
