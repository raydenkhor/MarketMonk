import 'package:flutter_test/flutter_test.dart';
import 'package:market_monk/image_import.dart';

void main() {
  group('parseHoldingsMarkdown', () {
    test('parses a markdown table from Mistral OCR', () {
      const markdown = '''
# Positions

|  Symbol | Description | Qty | Last Price | Mkt Value  |
| --- | --- | --- | --- | --- |
|  AAPL | Apple Inc. | 10.00 | 212.50 | 2,125.00  |
|  MSFT | Microsoft Corp. | 5.5 | 398.42 | 2,191.31  |
|  VOO | Vanguard S&P 500 ETF | 3.000 | 512.18 | 1,536.54  |
|  TSLA | Tesla, Inc. | 2 | 178.66 | 357.32  |
|  BRK.B | Berkshire Hathaway | 1 | 410.90 | 410.90  |
''';
      final holdings = parseHoldingsMarkdown(markdown);
      expect(holdings, hasLength(5));

      final aapl = holdings.firstWhere((h) => h.symbol == 'AAPL');
      expect(aapl.name, 'Apple Inc.');
      expect(aapl.quantity, 10.0);
      expect(aapl.price, 212.50);

      final msft = holdings.firstWhere((h) => h.symbol == 'MSFT');
      expect(msft.quantity, 5.5);
      expect(msft.price, 398.42);

      final brkb = holdings.firstWhere((h) => h.symbol == 'BRK.B');
      expect(brkb.quantity, 1.0);
      expect(brkb.price, 410.90);
    });

    test('strips exchange suffixes from symbols', () {
      const markdown = '''
| Symbol | Description | Qty | Price |
| --- | --- | --- | --- |
| RELIANCE.NS | Reliance Industries | 12 | 2,940.35 |
| INFY.NS | Infosys Ltd | 8 | 1,850.00 |
| BRK.B | Berkshire Hathaway | 3 | 410.90 |
''';
      final holdings = parseHoldingsMarkdown(markdown);
      final symbols = holdings.map((h) => h.symbol).toList();
      expect(symbols, containsAll(['RELIANCE', 'INFY', 'BRK.B']));
    });

    test('parses plain token lines without a table', () {
      const markdown = '''
AAPL Apple Inc. 10 212.50
MSFT Microsoft Corp. 5.5 398.42
TSLA Tesla, Inc. 2 178.66
''';
      final holdings = parseHoldingsMarkdown(markdown);
      expect(holdings, hasLength(3));

      final aapl = holdings.firstWhere((h) => h.symbol == 'AAPL');
      expect(aapl.quantity, 10.0);
      expect(aapl.price, 212.50);
      expect(aapl.name, 'Apple Inc.');
    });

    test('sums quantities when a symbol appears in multiple rows', () {
      const markdown = '''
| Symbol | Qty | Price |
| --- | --- | --- |
| AAPL | 3 | 210.00 |
| AAPL | 4 | 215.00 |
''';
      final holdings = parseHoldingsMarkdown(markdown);
      expect(holdings, hasLength(1));
      expect(holdings.single.quantity, 7.0);
      expect(holdings.single.price, 210.00);
    });

    test('leaves price null when it is missing from the image', () {
      const markdown = '''
| Symbol | Description | Qty | Price |
| --- | --- | --- | --- |
| AAPL | Apple Inc. | 10 |  |
''';
      final holdings = parseHoldingsMarkdown(markdown);
      expect(holdings, hasLength(1));
      expect(holdings.single.quantity, 10.0);
      expect(holdings.single.priceMissing, isTrue);
    });

    test('ignores headers, totals, cash and non-security rows', () {
      const markdown = '''
Account Summary
Cash \$12,345.67
Total Portfolio Value \$100,000.00

| Symbol | Qty | Price |
| --- | --- | --- |
| VOO | 5 | 512.00 |
''';
      final holdings = parseHoldingsMarkdown(markdown);
      expect(holdings, hasLength(1));
      expect(holdings.single.symbol, 'VOO');
    });

    test('returns empty list for garbage input', () {
      expect(parseHoldingsMarkdown(''), isEmpty);
      expect(
        parseHoldingsMarkdown('no holdings in this image at all 123456'),
        isEmpty,
      );
    });
  });
}
