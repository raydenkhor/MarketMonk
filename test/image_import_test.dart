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

    test(
      'parses an Interactive Brokers positions screenshot '
      '(real Mistral OCR output with UI glyphs, expander column, options)',
      () {
        // Real OCR output from the user's IBKR screenshot: headers carry
        // glyphs ("Symbol ▲", "Qty #"), data rows start with a ">" expander
        // cell the header lacks, symbols carry an "ⓘ" icon, and there is an
        // options row that must be skipped.
        const markdown = '''
Positions

Allocation

Performance

Historical value

Margin

Gains & Losses

Risk Assessment

Estimated Income

Shareholder Actions

Account

Rayden -0962

Net Account Value

\$91,918.53

Cash Purchasing Power ⓘ

\$46,810.93

Total Unrealized Gain

\$3,832.89 (8.70%)

Available for Withdrawal

\$46,810.93

Day's Gain Unrealized

-\$647.90 (-1.42%)

Show less

Transfer money

|  Filters |   | View | Filter by Symbol / CUSIP |   |   | Security type |   |   | Reset Sort ★ Customize |   |   | Wash sale adjustment ⓘ  |   |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
|   |   | All Positions |  |   |   | All securities |   |   |  |   |   |   |   |
|  Symbol ▲ |   |  | Actions | Last Price \$ | Change \$ | Change % | Qty # | Price Paid \$ | Day's Gain \$ | Total Gain \$ | Total Gain % | Value \$ |   |
|  > | BGC ⓘ | Trade | 11.77 | -0.20 | -1.67% | 600 | 10.4641 | -120.00 | 783.54 | 12.48% | 7,062.00 |  |   |
|  > | BGC ⓘ Aug 21 '26 \$10 Call | Trade | 0.65 | -0.025 | -1.27% | -6 | 2.32 | 15.00 | 218.87 | 15.76% | -1,170.00 |  |   |
|  > | CRMD ⓘ | Trade | 7.19 | -0.16 | -2.18% | 200 | 10.8969 | -32.00 | -741.38 | -34.02% | 1,438.00 |  |   |
|  > | DKNG ⓘ | Trade | 24.55 | -0.07 | -0.28% | 100 | 35.6655 | -7.00 | -1,111.55 | -31.17% | 2,455.00 |  |   |
|  > | GRAB ⓘ | Trade | 3.35 | -0.10 | -2.90% | 2000 | 6.2028 | -200.00 | -5,705.60 | -45.99% | 6,700.00 |  |   |
|  > | META ⓘ | Trade | 585.61 | -7.80 | -1.31% | 10 | 723.014 | -78.00 | -1,374.04 | -19.00% | 5,856.10 |  |   |
|  > | MSFT ⓘ | Trade | 390.54 | -2.81 | -0.71% | 10 | 401.61 | -28.10 | -110.70 | -2.76% | 3,905.40 |  |   |
|  > | NOW ⓘ | Trade | 115.76 | 5.14 | 4.65% | 20 | 99.1475 | 102.80 | 332.25 | 16.76% | 2,315.20 |  |   |
|  > | TSLA ⓘ | Trade | 298.32 | -9.12 | -2.97% | 40 | 19.44 | -364.80 | 11,155.20 | 1,434.57% | 11,932.80 |  |   |
|  > | ZS ⓘ | Trade | 153.77 | 2.14 | 1.41% | 30 | 140.8933 | 64.20 | 386.30 | 9.14% | 4,613.10 |  |   |
|  Viewing 10 of 10 positions  |   |   |   |   |   |   |   |   |   |   |   |   |   |
''';
        final skipped = <String>[];
        final holdings = parseHoldingsMarkdown(markdown, skipped: skipped);
        expect(holdings, hasLength(9));
        final bySymbol = {for (final h in holdings) h.symbol: h};
        expect(bySymbol['BGC']!.quantity, 600.0);
        expect(bySymbol['BGC']!.price, 11.77);
        expect(bySymbol['CRMD']!.quantity, 200.0);
        expect(bySymbol['CRMD']!.price, 7.19);
        expect(bySymbol['DKNG']!.quantity, 100.0);
        expect(bySymbol['DKNG']!.price, 24.55);
        expect(bySymbol['GRAB']!.quantity, 2000.0);
        expect(bySymbol['GRAB']!.price, 3.35);
        expect(bySymbol['META']!.quantity, 10.0);
        expect(bySymbol['META']!.price, 585.61);
        expect(bySymbol['MSFT']!.quantity, 10.0);
        expect(bySymbol['MSFT']!.price, 390.54);
        expect(bySymbol['NOW']!.quantity, 20.0);
        expect(bySymbol['NOW']!.price, 115.76);
        expect(bySymbol['TSLA']!.quantity, 40.0);
        expect(bySymbol['TSLA']!.price, 298.32);
        expect(bySymbol['ZS']!.quantity, 30.0);
        expect(bySymbol['ZS']!.price, 153.77);

        // The short BGC call option must not be imported as a holding, and
        // it must be surfaced as skipped so the user knows it was ignored.
        expect(holdings.where((h) => h.symbol == 'BGC'), hasLength(1));
        expect(skipped, hasLength(1));
        expect(skipped.single, contains('BGC ⓘ Aug 21'));
      },
    );
  });
}
