import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:market_monk/database.dart';
import 'package:market_monk/main.dart';
import 'package:market_monk/settings_state.dart';
import 'package:market_monk/utils.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A single security holding extracted from a holdings screenshot.
class ImageHolding {
  final String symbol;
  final String name;
  final double quantity;

  /// Price per share if visible in the image or resolved from a live quote.
  double? price;

  ImageHolding({
    required this.symbol,
    required this.name,
    required this.quantity,
    this.price,
  });

  bool get priceMissing => price == null;
}

class HoldingsImageParseException implements Exception {
  final String message;
  const HoldingsImageParseException(this.message);
  @override
  String toString() => message;
}

/// Mistral API key baked in at build time:
/// `flutter build apk --dart-define=MISTRAL_API_KEY=...`
const String kMistralApiKey = String.fromEnvironment('MISTRAL_API_KEY');

/// OCR model name, overridable at build time.
const String kMistralOcrModel = String.fromEnvironment(
  'MISTRAL_OCR_MODEL',
  defaultValue: 'mistral-ocr-latest',
);

const String _ocrEndpoint = 'https://api.mistral.ai/v1/ocr';

/// Resolves the Mistral API key: a device-stored override (set in
/// Settings → Data → Mistral API key) wins over the build-time dart-define.
Future<String> _resolveApiKey() async {
  final prefs = await SharedPreferences.getInstance();
  final override = prefs.getString('mistralApiKey');
  if (override != null && override.trim().isNotEmpty) return override.trim();
  if (kMistralApiKey.isNotEmpty) return kMistralApiKey;
  throw const HoldingsImageParseException(
    'No Mistral API key configured. '
    'Set one in Settings → Data → Mistral API key.',
  );
}

/// Runs the full import flow: pick an image, OCR it with Mistral, let the
/// user confirm the parsed holdings, then write them to the portfolio.
Future<void> importHoldingsFromImage(BuildContext context) async {
  final result = await FilePicker.pickFiles(type: FileType.image);
  if (result == null || !context.mounted) return;
  final path = result.files.single.path;
  if (path == null) return;

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const Center(child: CircularProgressIndicator()),
  );

  List<ImageHolding> holdings;
  final skipped = <String>[];
  try {
    holdings = await parseHoldingsImage(path, skipped: skipped);
  } on HoldingsImageParseException catch (e) {
    if (context.mounted) Navigator.pop(context);
    if (context.mounted) toast(context, e.message);
    return;
  } catch (e) {
    if (context.mounted) Navigator.pop(context);
    if (context.mounted) toast(context, 'Failed to read image: $e');
    return;
  }
  if (context.mounted) Navigator.pop(context);

  if (holdings.isEmpty) {
    if (context.mounted) {
      toast(context, 'No holdings recognized in the image');
    }
    return;
  }

  // Fill missing prices with live quotes so the cost basis is meaningful.
  final missing = holdings.where((h) => h.priceMissing).toList();
  if (missing.isNotEmpty) {
    final quotes =
        await Future.wait(missing.map((h) => fetchCurrentPrice(h.symbol)));
    for (var i = 0; i < missing.length; i++) {
      missing[i].price = quotes[i];
    }
  }

  final unknownCount = holdings.where((h) => h.priceMissing).length;

  // Detect symbols that already have trades so a re-import of the same
  // screenshot doesn't silently double every position.
  final alreadyHeld = <String>[];
  try {
    final trades = await db.trades.select().get();
    final held = trades.map((t) => t.symbol).toSet();
    alreadyHeld.addAll(
      holdings.where((h) => held.contains(h.symbol)).map((h) => h.symbol),
    );
  } catch (_) {
    // Best effort — the import itself is still safe.
  }

  if (!context.mounted) return;

  var confirmed = false;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(
        'Import ${holdings.length} holding${holdings.length == 1 ? '' : 's'}?',
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView(
          shrinkWrap: true,
          children: [
            ...holdings.take(10).map(
                  (h) => ListTile(
                    dense: true,
                    title: Text(h.symbol),
                    subtitle: Text(h.name),
                    trailing: Text(
                      '${_fmtQty(h.quantity)} @ '
                      '${h.price != null ? '${symbolPriceUnit(h.symbol)}${h.price!.toStringAsFixed(2)}' : 'price unknown'}',
                    ),
                  ),
                ),
            if (holdings.length > 10)
              ListTile(
                dense: true,
                title: Text(
                  '... and ${holdings.length - 10} more holdings',
                  style: const TextStyle(fontStyle: FontStyle.italic),
                ),
              ),
            if (skipped.isNotEmpty) ...[
              const Divider(),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  'Skipped ${skipped.length} non-stock row'
                  '${skipped.length == 1 ? '' : 's'} (options, shorts, '
                  'unknown symbols):',
                  style: const TextStyle(fontStyle: FontStyle.italic),
                ),
              ),
              ...skipped.take(5).map(
                    (s) => Padding(
                      padding: const EdgeInsets.only(left: 8, bottom: 2),
                      child: Text(s, style: const TextStyle(fontSize: 12)),
                    ),
                  ),
            ],
            if (alreadyHeld.isNotEmpty) ...[
              const Divider(),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '${alreadyHeld.length} of these symbols already have '
                  'trades: ${alreadyHeld.take(5).join(', ')}'
                  '${alreadyHeld.length > 5 ? ', …' : ''} — importing will '
                  'ADD to the existing quantities. Cancel to avoid '
                  'duplicates.',
                  style: const TextStyle(fontStyle: FontStyle.italic),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () {
            confirmed = true;
            Navigator.pop(context);
          },
          child: const Text('Import'),
        ),
      ],
    ),
  );

  if (!confirmed || !context.mounted) return;

  final count = await importHoldings(holdings);
  if (!context.mounted) return;
  context.read<SettingsState>().notifyTradesImported();
  final suffix =
      unknownCount > 0 ? ' ($unknownCount price unknown — tap to edit)' : '';
  toast(context, 'Imported $count holding${count == 1 ? '' : 's'}$suffix');
}

String _fmtQty(double q) => q % 1 == 0 ? q.toInt().toString() : q.toString();

/// OCRs the image at [imagePath] and returns the parsed holdings.
/// Unimportable rows (options, shorts) are appended to [skipped].
Future<List<ImageHolding>> parseHoldingsImage(
  String imagePath, {
  List<String>? skipped,
}) async {
  final apiKey = await _resolveApiKey();
  final markdown = await _ocrMarkdown(imagePath, apiKey);
  return parseHoldingsMarkdown(markdown, skipped: skipped);
}

Future<String> _ocrMarkdown(String imagePath, String apiKey) async {
  final bytes = await File(imagePath).readAsBytes();
  final b64 = base64Encode(bytes);
  final ext = p.extension(imagePath).toLowerCase();
  final mime = switch (ext) {
    '.jpg' || '.jpeg' => 'image/jpeg',
    '.webp' => 'image/webp',
    _ => 'image/png',
  };

  final response = await http
      .post(
        Uri.parse(_ocrEndpoint),
        headers: {
          'Authorization': 'Bearer $apiKey',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'model': kMistralOcrModel,
          'document': {
            'type': 'image_url',
            'image_url': 'data:$mime;base64,$b64',
          },
        }),
      )
      .timeout(const Duration(seconds: 60));

  if (response.statusCode == 401) {
    throw const HoldingsImageParseException(
      'Mistral API rejected the key (401). '
      'Check Settings → Data → Mistral API key.',
    );
  }
  if (response.statusCode != 200) {
    throw HoldingsImageParseException(
      'Mistral OCR failed (HTTP ${response.statusCode}).',
    );
  }

  final data = jsonDecode(response.body) as Map<String, dynamic>;
  final pages = data['pages'] as List? ?? const [];
  final markdown = pages
      .map((p) => (p as Map<String, dynamic>)['markdown'] as String? ?? '')
      .join('\n');
  if (markdown.trim().isEmpty) {
    throw const HoldingsImageParseException(
      'No text was recognized in the image',
    );
  }
  return markdown;
}

/// Parses Mistral OCR markdown output into holdings.
///
/// Handles two shapes: markdown tables (`| AAPL | Apple Inc. | 10 | ... |`)
/// and plain token lines (`AAPL Apple Inc. 10 212.50`). Rows for the same
/// symbol are merged by summing quantities. Rows that are deliberately not
/// imported (options, short positions, unrecognized symbols) are appended to
/// [skipped] as human-readable descriptions when provided.
List<ImageHolding> parseHoldingsMarkdown(
  String markdown, {
  List<String>? skipped,
}) {
  final bySymbol = <String, _HoldingAccum>{};
  // Parsing is stateless per call: a stale header from a previous import
  // would mis-map the first rows of a table whose header OCR missed.
  _currentHeader = null;

  for (final rawLine in markdown.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;

    if (line.startsWith('|')) {
      final cells = line
          .split('|')
          .map((c) => c.trim())
          .where((c) => c.isNotEmpty)
          .toList();
      if (cells.isEmpty) continue;
      if (cells.every((c) => RegExp(r'^-{2,}$').hasMatch(c))) continue;

      final headerIndices = _headerIndices(cells);
      if (headerIndices != null) {
        // A header row — subsequent rows are parsed with column mapping.
        _currentHeader = headerIndices;
        continue;
      }
      _ingestRow(bySymbol, cells, _currentHeader, skipped);
    } else {
      _parsePlainLine(bySymbol, line, skipped);
    }
  }

  final holdings = bySymbol.entries
      .where((e) => e.value.quantity > 0)
      .map(
        (e) => ImageHolding(
          symbol: e.key,
          name: e.value.name,
          quantity: e.value.quantity,
          price: e.value.price,
        ),
      )
      .toList()
    ..sort((a, b) => a.symbol.compareTo(b.symbol));
  return holdings;
}

_HeaderIndices? _currentHeader;

class _HeaderIndices {
  final int? symbol;
  final int? quantity;

  /// Cost-basis column ("Price Paid", "Avg Cost") — preferred for the buy
  /// price so P/L is computed against what was actually paid.
  final int? cost;

  /// Current-price column ("Last Price") — fallback when no cost column.
  final int? price;
  final int? name;
  _HeaderIndices({
    this.symbol,
    this.quantity,
    this.cost,
    this.price,
    this.name,
  });
}

_HeaderIndices? _headerIndices(List<String> cells) {
  if (cells.length < 2) return null;
  int? symbol, quantity, cost, price, name;
  for (var i = 0; i < cells.length; i++) {
    // OCR apps attach UI glyphs to header text ("Symbol ▲", "Qty #",
    // "Last Price $"). Strip everything except letters/digits/spaces so
    // those headers still match.
    final label =
        cells[i].toLowerCase().replaceAll(RegExp(r'[^a-z0-9 ]'), '').trim();
    if (label == 'symbol' || label == 'ticker' || label == 'code') {
      symbol ??= i;
    } else if (label == 'qty' ||
        label == 'quantity' ||
        label == 'shares' ||
        label == 'amount' ||
        label == 'units' ||
        label == 'holdings' ||
        label == 'position' ||
        label == 'size') {
      quantity ??= i;
    } else if (label.contains('price paid') || label.contains('cost')) {
      cost ??= i;
    } else if (label.contains('price') || label == 'nav' || label == 'last') {
      price ??= i;
    } else if (label == 'name' ||
        label == 'description' ||
        label == 'company' ||
        label == 'security') {
      name ??= i;
    }
  }
  if (symbol == null && quantity == null) return null;
  return _HeaderIndices(
    symbol: symbol,
    quantity: quantity,
    cost: cost,
    price: price,
    name: name,
  );
}

void _ingestRow(
  Map<String, _HoldingAccum> bySymbol,
  List<String> cells,
  _HeaderIndices? header,
  List<String>? skipped,
) {
  String? symbol;
  String name = '';
  double? quantity;
  double? price;

  final symbolIdx = header?.symbol;
  final quantityIdx = header?.quantity;
  final costIdx = header?.cost;
  final priceIdx = header?.price;
  final nameIdx = header?.name;

  // OCR tables sometimes gain a leading cell versus the header (e.g. a ">"
  // expander before the symbol). Locate the symbol first, then shift every
  // mapped column by the same offset so quantity/price stay aligned.
  var offset = 0;
  if (symbolIdx != null && symbolIdx < cells.length) {
    symbol = _cleanSymbol(cells[symbolIdx]);
  }
  if (symbol == null || !_isTicker(symbol)) {
    for (var i = symbolIdx ?? 0; i < cells.length; i++) {
      final c = cells[i];
      // Heuristic matches only require uppercase ASCII letters (OCR tables
      // render tickers in caps; prose like "No" or "At" is almost always
      // mixed case). Cannot use c == c.toUpperCase(): circled glyphs such as
      // "ⓘ" case-map to "Ⓘ", breaking the comparison for every row.
      if (_allCaps(c) && _isTicker(_cleanSymbol(c))) {
        symbol = _cleanSymbol(c);
        offset = symbolIdx == null ? 0 : i - symbolIdx;
        break;
      }
    }
  }
  // The header-column cell can yield an empty string (e.g. a ">" expander);
  // without a valid ticker the row must be discarded, not merged under "".
  if (symbol == null || !_isTicker(symbol)) {
    // Only surface rows that look like data (contain a number) — filters,
    // captions and other chrome would otherwise be reported as "skipped".
    final hasNumeric = cells.any((c) => _parseNumber(c) != null);
    if (hasNumeric && skipped != null) {
      final label = cells.firstWhere(
        (c) => RegExp(r'[a-zA-Z]').hasMatch(c),
        orElse: () => cells.first,
      );
      // Pager/caption rows ("Viewing 10 of 10 positions") are chrome, not
      // skipped holdings.
      final isFooter = RegExp(
        r'^(viewing|showing|displaying|page|rows?|items?|records?)\b',
        caseSensitive: false,
      ).hasMatch(label);
      if (!isFooter) {
        skipped.add(
          '${label.length > 48 ? label.substring(0, 48) : label} — option or '
          'unrecognized symbol',
        );
      }
    }
    return;
  }

  int? shifted(int? idx) =>
      idx != null && idx + offset < cells.length ? idx + offset : null;

  final qtyIdx = shifted(quantityIdx);
  if (qtyIdx != null && !cells[qtyIdx].contains('%')) {
    quantity = _parseNumber(cells[qtyIdx]);
  }
  // The mapped qty cell can be off by one as well; probe its neighbors
  // before falling back to the free-form scan below.
  if (quantity == null || quantity <= 0) {
    for (final probe in [
      qtyIdx == null ? null : qtyIdx + 1,
      qtyIdx == null || qtyIdx == 0 ? null : qtyIdx - 1,
    ]) {
      if (probe == null || probe >= cells.length) continue;
      final cell = cells[probe];
      if (cell.contains('%')) continue;
      final v = _parseNumber(cell);
      if (v != null && v > 0) {
        quantity = v;
        break;
      }
    }
  }

  final cIdx = shifted(costIdx);
  final pIdx = shifted(priceIdx);
  // Prefer the cost-basis column ("Price Paid" / "Avg Cost") — that is the
  // price the position was actually bought at. Fall back to the current
  // price column only when the screenshot has no cost column at all.
  if (cIdx != null && !cells[cIdx].contains('%')) {
    price = _parseNumber(cells[cIdx]);
  }
  if (price == null && pIdx != null && !cells[pIdx].contains('%')) {
    price = _parseNumber(cells[pIdx]);
  }
  final nIdx = shifted(nameIdx);
  if (nIdx != null) {
    name = cells[nIdx];
  }

  if (quantity == null) {
    for (var i = 0; i < cells.length; i++) {
      if (i == pIdx) continue;
      final cell = cells[i];
      if (cell.contains('%')) continue;
      if (RegExp(r'^[€£$¥]').hasMatch(cell)) continue;
      final v = _parseNumber(cell);
      if (v != null) {
        quantity = v;
        break;
      }
    }
  }
  if (price == null) {
    for (final cell in cells) {
      if (cell.contains('\$') || cell.startsWith('€') || cell.startsWith('£')) {
        final v = _parseNumber(cell.replaceAll(RegExp(r'[^\d.,-]'), ''));
        if (v != null) {
          price = v;
          break;
        }
      }
    }
  }
  if (name.isEmpty) {
    for (final cell in cells) {
      final s = _cleanSymbol(cell);
      if (!_isTicker(s) &&
          _parseNumber(cell) == null &&
          RegExp(r'[a-z]', caseSensitive: false).hasMatch(cell)) {
        name = cell;
        break;
      }
    }
  }

  if (quantity == null || quantity <= 0) {
    if (skipped != null) {
      if (quantity != null && quantity < 0) {
        skipped.add('$symbol — short position (qty ${_fmtQty(quantity)})');
      } else {
        skipped.add('$symbol — no positive quantity found');
      }
    }
    return;
  }

  final acc = bySymbol.putIfAbsent(
    symbol,
    () => _HoldingAccum(name: name, price: price),
  );
  acc.quantity += quantity;
  if (acc.name.isEmpty) acc.name = name;
  acc.price ??= price;
}

void _parsePlainLine(
  Map<String, _HoldingAccum> bySymbol,
  String line,
  List<String>? skipped,
) {
  final tokens = line.split(RegExp(r'\s+'));
  int? symbolIdx;
  for (var i = 0; i < tokens.length; i++) {
    final token = tokens[i];
    // Tickers appear in caps in holdings screenshots; lowercase prose words
    // ("no", "at", "of") are never valid symbols.
    if (_allCaps(token) && _isTicker(_cleanSymbol(token))) {
      symbolIdx = i;
      break;
    }
  }
  if (symbolIdx == null) return;
  final symbol = _cleanSymbol(tokens[symbolIdx]);

  final nameParts = <String>[];
  double? quantity;
  double? price;
  for (var i = symbolIdx + 1; i < tokens.length; i++) {
    final t = tokens[i];
    if (t.startsWith('\$')) {
      final v = _parseNumber(t.replaceAll(RegExp(r'[^\d.,-]'), ''));
      if (v != null) price = v;
      continue;
    }
    final v = _parseNumber(t);
    if (v != null) {
      if (quantity == null) {
        quantity = v;
      } else {
        price ??= v;
      }
    } else if (quantity == null &&
        RegExp(r'[a-z]{2}', caseSensitive: false).hasMatch(t)) {
      nameParts.add(t);
    }
  }
  if (quantity == null || quantity <= 0) {
    if (skipped != null) {
      skipped.add(
        quantity != null && quantity < 0
            ? '$symbol — short position (qty ${_fmtQty(quantity)})'
            : '$symbol — no positive quantity found',
      );
    }
    return;
  }

  final acc = bySymbol.putIfAbsent(
    symbol,
    () => _HoldingAccum(name: nameParts.join(' '), price: price),
  );
  acc.quantity += quantity;
  if (acc.name.isEmpty && nameParts.isNotEmpty) acc.name = nameParts.join(' ');
  acc.price ??= price;
}

class _HoldingAccum {
  String name;
  double? price;
  double quantity = 0;
  _HoldingAccum({required this.name, this.price});
}

/// Writes [holdings] as open trades (buy) dated now.
Future<int> importHoldings(List<ImageHolding> holdings) async {
  final now = DateTime.now();
  var count = 0;
  for (final h in holdings) {
    await db.trades.insertOne(
      TradesCompanion.insert(
        symbol: h.symbol,
        name: h.name.isEmpty ? h.symbol : h.name,
        quantity: h.quantity,
        price: h.price ?? 0.0,
        tradeType: 'open',
        tradeDate: now,
      ),
    );
    unawaited(_warmCandles(h.symbol));
    count++;
  }
  return count;
}

Future<void> _warmCandles(String symbol) async {
  try {
    await syncCandles(symbol);
  } catch (_) {
    // Charts populate on the next manual refresh if the fetch fails here.
  }
}

/// Fetches the latest trade price for [symbol] from Yahoo Finance.
/// Returns null when unavailable. Used to fill in prices not visible in a
/// holdings screenshot.
Future<double?> fetchCurrentPrice(String symbol) async {
  try {
    final uri = Uri.parse(
      'https://query1.finance.yahoo.com/v8/finance/chart/$symbol'
      '?interval=1d&range=1d',
    );
    final response = await http.get(uri).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) return null;
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final chart = data['chart'] as Map<String, dynamic>?;
    final result = (chart?['result'] as List?)?.firstOrNull as Map?;
    final meta = result?['meta'] as Map<String, dynamic>?;
    final price = meta?['regularMarketPrice'] as num?;
    return price?.toDouble();
  } catch (_) {
    return null;
  }
}

const Set<String> _exchangeSuffixes = {
  'NS',
  'BO',
  'NSE',
  'BSE',
  'L',
  'LN',
  'DE',
  'F',
  'PA',
  'AS',
  'AX',
  'T',
  'V',
  'TO',
  'MI',
  'MC',
  'HK',
  'SS',
  'SZ',
  'KS',
  'KQ',
  'TW',
  'JK',
  'ST',
  'OL',
  'CO',
  'ME',
  'MX',
  'TA',
  'SN',
  'SW',
  'VI',
  'WA',
  'NZ',
  'SI',
};

const Set<String> _headerWords = {
  'SYMBOL',
  'TICKER',
  'CODE',
  'QTY',
  'QUANTITY',
  'SHARES',
  'AMOUNT',
  'UNITS',
  'HOLDINGS',
  'POSITION',
  'POSITIONS',
  'SIZE',
  'PRICE',
  'LAST',
  'COST',
  'NAME',
  'DESCRIPTION',
  'COMPANY',
  'SECURITY',
  'VALUE',
  'TOTAL',
  'CASH',
  'MARKET',
  'BALANCE',
  'PORTFOLIO',
  'CURRENCY',
  'DAY',
  'GAIN',
  'LOSS',
  'P/L',
  'PL',
  'TOTALVALUE',
  'ASSET',
  'CLASS',
  'SECTOR',
  'NO',
  'IN',
  'AT',
  'ALL',
  'THIS',
  'IMAGE',
  'OF',
  'THE',
  'AND',
  'FOR',
  'WITH',
  'FROM',
  'YOUR',
  'NOT',
  'FOUND',
  'DATA',
  'ITEMS',
  'ROW',
};

String _cleanSymbol(String raw) {
  var s = raw.trim().toUpperCase().replaceAll(RegExp(r'\s+'), '');
  // OCR attaches UI glyphs to symbols ("BGC ⓘ", "BRK.B ⓘ"). Strip
  // everything that cannot be part of a ticker before exchange handling.
  s = s.replaceAll(RegExp(r'[^A-Z0-9.\-]'), '');
  final exchangeMatch =
      RegExp(r'^([A-Z][A-Z0-9.]{0,9})\.([A-Z]{1,3})$').firstMatch(s);
  if (exchangeMatch != null &&
      _exchangeSuffixes.contains(exchangeMatch.group(2))) {
    s = exchangeMatch.group(1)!;
  }
  return s;
}

bool _isTicker(String s) {
  if (s.isEmpty) return false;
  if (_headerWords.contains(s)) return false;
  // Up to 10 chars to cover international tickers (e.g. RELIANCE,
  // TATAMOTORS); class shares like BRK.B and BRK-B are allowed.
  return RegExp(r'^[A-Z][A-Z0-9.\-]{0,9}$').hasMatch(s);
}

/// True when every ASCII letter in [s] is uppercase. The cell may still
/// carry digits and UI glyphs (">", "ⓘ"); those are ignored.
bool _allCaps(String s) {
  final letters =
      RegExp(r'[a-zA-Z]').allMatches(s).map((m) => m.group(0)!).toList();
  return letters.isNotEmpty && letters.every((ch) => ch == ch.toUpperCase());
}

double? _parseNumber(String raw) {
  // Up to 9 integer digits so comma-less four+ digit values ("2000") parse
  // whole instead of truncating to the first three digits.
  final m =
      RegExp(r'-?\d{1,9}(,\d{3})*(\.\d+)?|\d+\.\d+|\d+').firstMatch(raw.trim());
  if (m == null) return null;
  return double.tryParse(m.group(0)!.replaceAll(',', ''));
}
