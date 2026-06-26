import 'dart:convert';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

// ─── App Settings & Persistence ──────────────────────────────────────────────
class AppSettings {
  static const String _groqKeyPref = "groq_api_key";
  static const String _groqModel = "llama-3.3-70b-versatile";
  static const String groqEndpoint =
      "https://api.groq.com/openai/v1/chat/completions";

  static Future<String> getGroqKey() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_groqKeyPref) ?? '';
  }

  static Future<void> setGroqKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_groqKeyPref, key.trim());
  }

  static String get model => _groqModel;
}

// ─── Search Engine ────────────────────────────────────────────────────────────
class BylawsSearchEngine {
  final List<String> _sections = [];
  bool isLoaded = false;

  // BM25 parameters
  static const double _k1 = 1.2;
  static const double _b = 0.75;

  // BM25 statistics
  final List<double> _docLengths = [];
  double _avgDocLength = 0;
  final List<Map<String, int>> _docTermFrequencies = [];
  final Map<String, List<int>> _invertedIndex = {}; // term -> doc indices

  // English stop words to ignore during search
  static const Set<String> _stopWords = {
    'a', 'an', 'the', 'is', 'are', 'was', 'were', 'be', 'been', 'being',
    'have', 'has', 'had', 'do', 'does', 'did', 'will', 'would', 'could', 'should',
    'may', 'might', 'shall', 'must', 'can', 'need', 'dare', 'ought', 'used',
    'to', 'of', 'in', 'for', 'on', 'with', 'at', 'by', 'from', 'as', 'into',
    'through', 'during', 'before', 'after', 'above', 'below', 'up', 'down', 'out',
    'off', 'over', 'under', 'again', 'then', 'once', 'and', 'but', 'or', 'nor',
    'not', 'so', 'yet', 'both', 'either', 'neither', 'whether', 'if', 'that',
    'this', 'these', 'those', 'what', 'which', 'who', 'how', 'when', 'where',
    'why', 'all', 'each', 'every', 'more', 'most', 'other', 'some', 'such',
    'no', 'only', 'same', 'than', 'too', 'very', 'just', 'i', 'you', 'he',
    'she', 'it', 'we', 'they', 'me', 'him', 'her', 'us', 'them', 'my', 'your',
    'his', 'its', 'our', 'their', 'any', 'few', 'much', 'many', 'also', 'while',
  };

  // Regex to check if a string contains Arabic characters
  static final RegExp _arabicRegex = RegExp(r'[\u0600-\u06FF]');

  // Arabic Normalization
  static String _normalizeArabic(String text) {
    text = text.replaceAll(RegExp(r'[\u064B-\u0652\u0670]'), ''); // Remove diacritics
    text = text.replaceAll(RegExp(r'\u0640'), ''); // Remove Tatweel
    text = text.replaceAll(RegExp(r'[أإآ]'), 'ا'); // Normalize Alef
    text = text.replaceAll(RegExp(r'ة'), 'ه'); // Normalize Teh Marbuta
    text = text.replaceAll(RegExp(r'ى'), 'ي'); // Normalize Alef Maksura
    return text.trim();
  }

  // Arabic Prefix/Stemming
  static String _stemArabic(String word) {
    if (word.length <= 3) return word;
    if (word.startsWith('وال') || word.startsWith('فال') || word.startsWith('بال')) {
      word = word.substring(3);
    } else if (word.startsWith('ال') || word.startsWith('لل')) {
      word = word.substring(2);
    } else if (word.startsWith('و') && word.length > 3) {
      word = word.substring(1);
    }
    return word;
  }

  // Predefined Arabic to English mapping
  static const Map<String, List<String>> _arabicToEnglishDict = {
    'تخرج': ['graduat', 'graduating', 'graduation', 'degree', 'award'],
    'معدل': ['gpa', 'cgpa', 'grade', 'points', 'average'],
    'رسوب': ['fail', 'failure', 'probation', 'dismissal', 'observation'],
    'راسب': ['fail', 'failure', 'repeat', 'probation'],
    'نجاح': ['pass', 'passed', 'passing', 'grade', 'marks'],
    'ناجح': ['pass', 'passed'],
    'غياب': ['absent', 'absence', 'attendance', 'attend'],
    'حضور': ['attend', 'attendance'],
    'انذار': ['probation', 'dismissal', 'warning', 'observation'],
    'فصل': ['dismiss', 'dismissal', 'suspend', 'suspension', 'semester', 'term'],
    'سحب': ['withdraw', 'withdrawal', 'drop'],
    'انسحاب': ['withdraw', 'withdrawal', 'drop'],
    'اضافه': ['add', 'adding'],
    'حذف': ['drop', 'dropping'],
    'ساعه': ['hour', 'hours', 'credit'],
    'ساعات': ['hour', 'hours', 'credit'],
    'معتمده': ['credit'],
    'تدريب': ['train', 'training', 'field'],
    'ميداني': ['field'],
    'تسجيل': ['regist', 'register', 'registration', 'enroll', 'enrollment'],
    'رسوم': ['fee', 'fees', 'tuition', 'pay', 'payment'],
    'مصاريف': ['fee', 'fees', 'tuition', 'pay', 'payment'],
    'مشروع': ['project'],
    'اختبار': ['exam', 'exams', 'examination', 'test', 'placement'],
    'امتحان': ['exam', 'exams', 'examination', 'test'],
    'مستوى': ['level', 'levels'],
    'مستويات': ['level', 'levels'],
    'سمستر': ['semester', 'semesters', 'term'],
    'صيفي': ['summer'],
    'قبول': ['admission', 'admitted', 'enrollment'],
    'شروط': ['requirement', 'requirements', 'rules', 'terms'],
    'متطلبات': ['requirement', 'requirements', 'rules'],
    'قوانين': ['rules', 'regulations', 'bylaw'],
    'لائحه': ['bylaw', 'regulation', 'regulations', 'rules'],
    'ماده': ['course', 'courses', 'module', 'modules'],
    'مواد': ['course', 'courses', 'module', 'modules'],
    'منهج': ['curriculum', 'curricula'],
    'دراسه': ['study', 'academic'],
  };

  // English synonyms
  static const Map<String, List<String>> _englishSynonyms = {
    'gpa': ['cgpa', 'grade', 'average', 'points'],
    'cgpa': ['gpa', 'grade', 'average', 'points'],
    'graduation': ['graduate', 'degree', 'award', 'requirements'],
    'graduate': ['graduation', 'degree', 'requirements'],
    'probation': ['dismissal', 'dismissed', 'warning', 'gpa', 'observation'],
    'withdraw': ['withdrawal', 'drop'],
    'withdrawal': ['withdraw', 'drop'],
    'fees': ['fee', 'tuition', 'pay', 'payment'],
    'tuition': ['fees', 'fee', 'pay', 'payment'],
    'training': ['train', 'field'],
    'project': ['graduation', 'project'],
    'exam': ['exams', 'examination', 'test'],
    'exams': ['exam', 'examination', 'test'],
    'test': ['placement', 'exam', 'exams'],
    'level': ['levels'],
    'semester': ['semesters', 'term', 'terms'],
    'summer': ['semester', 'semesters'],
  };

  Future<void> load() async {
    final raw = await rootBundle.loadString("assets/bylaws.txt");
    // Split into paragraphs by newlines (filter empty ones)
    final paragraphs = raw
        .split(RegExp(r'\n{1,}'))
        .map((p) => p.trim())
        .where((p) => p.length > 80) // Only meaningful paragraphs
        .toList();

    _sections.clear();
    _sections.addAll(paragraphs);

    _docLengths.clear();
    _docTermFrequencies.clear();
    _invertedIndex.clear();

    double totalLength = 0;
    for (int i = 0; i < _sections.length; i++) {
      final tokens = _tokenize(_sections[i]);
      final docLen = tokens.length.toDouble();
      _docLengths.add(docLen);
      totalLength += docLen;

      final Map<String, int> termFreqs = {};
      for (final token in tokens) {
        termFreqs[token] = (termFreqs[token] ?? 0) + 1;
      }
      _docTermFrequencies.add(termFreqs);

      for (final term in termFreqs.keys) {
        if (!_invertedIndex.containsKey(term)) {
          _invertedIndex[term] = [];
        }
        _invertedIndex[term]!.add(i);
      }
    }

    _avgDocLength = _sections.isEmpty ? 0 : totalLength / _sections.length;
    isLoaded = true;
  }

  static List<String> _tokenize(String text) {
    return text
        .toLowerCase()
        // Keep alphanumeric English words and Arabic characters
        .replaceAll(RegExp(r'[^\w\s\u0600-\u06FF]'), ' ')
        .split(RegExp(r'\s+'))
        .where((w) => w.length > 1 && !_stopWords.contains(w))
        .toList();
  }

  static List<String> expandQuery(String query) {
    final originalTokens = _tokenize(query);
    final Set<String> expandedTokens = {};

    for (final token in originalTokens) {
      expandedTokens.add(token);

      if (_arabicRegex.hasMatch(token)) {
        final normalized = _normalizeArabic(token);
        final stemmed = _stemArabic(normalized);

        final englishTerms = _arabicToEnglishDict[stemmed];
        if (englishTerms != null) {
          expandedTokens.addAll(englishTerms.map((t) => t.toLowerCase()));
        }
        expandedTokens.add(normalized);
        expandedTokens.add(stemmed);
      } else {
        final synonyms = _englishSynonyms[token];
        if (synonyms != null) {
          expandedTokens.addAll(synonyms);
        }
      }
    }
    return expandedTokens.toList();
  }

  double _idf(String term) {
    final n = _invertedIndex[term]?.length ?? 0;
    final N = _sections.length;
    return log(1.0 + (N - n + 0.5) / (n + 0.5));
  }

  double _bm25Score(int i, List<String> queryTokens) {
    double score = 0;
    final docLen = _docLengths[i];
    final termFreqs = _docTermFrequencies[i];

    for (final qt in queryTokens) {
      final tf = termFreqs[qt]?.toDouble() ?? 0.0;
      if (tf > 0) {
        final idf = _idf(qt);
        final numerator = tf * (_k1 + 1);
        final denominator = tf + _k1 * (1.0 - _b + _b * (docLen / _avgDocLength));
        score += idf * (numerator / denominator);
      }
    }
    return score;
  }

  List<SearchResult> search(String query, {int topK = 5}) {
    if (!isLoaded || query.trim().isEmpty) return [];
    final queryTokens = expandQuery(query);
    if (queryTokens.isEmpty) return [];

    final scored = <SearchResult>[];
    for (int i = 0; i < _sections.length; i++) {
      final s = _bm25Score(i, queryTokens);
      if (s > 0) {
        scored.add(SearchResult(text: _sections[i], score: s, index: i));
      }
    }

    scored.sort((a, b) => b.score.compareTo(a.score));

    // Deduplicate very similar results
    final results = <SearchResult>[];
    for (final r in scored) {
      bool tooSimilar = false;
      for (final existing in results) {
        if (_similarity(r.text, existing.text) > 0.7) {
          tooSimilar = true;
          break;
        }
      }
      if (!tooSimilar) results.add(r);
      if (results.length >= topK) break;
    }
    return results;
  }

  double _similarity(String a, String b) {
    final aWords = _tokenize(a).toSet();
    final bWords = _tokenize(b).toSet();
    final intersection = aWords.intersection(bWords).length;
    final union = aWords.union(bWords).length;
    return union == 0 ? 0 : intersection / union;
  }
}

class SearchResult {
  final String text;
  final double score;
  final int index;
  SearchResult({required this.text, required this.score, required this.index});
}

enum ChatMode {
  offlineSearch,
  aiAssistant,
}

// ─── Chat Message Model ───────────────────────────────────────────────────────
class ChatMessage {
  final String text;
  final bool isUser;
  final List<SearchResult> results;
  final bool isAi;

  const ChatMessage({
    required this.text,
    required this.isUser,
    this.results = const [],
    this.isAi = false,
  });
}

// ─── Highlight Text Widget ───────────────────────────────────────────────────
class HighlightText extends StatelessWidget {
  final String text;
  final String query;
  final TextStyle style;
  final Color highlightColor;

  const HighlightText({
    super.key,
    required this.text,
    required this.query,
    required this.style,
    required this.highlightColor,
  });

  @override
  Widget build(BuildContext context) {
    if (query.trim().isEmpty) {
      return Text(text, style: style);
    }

    final tokens = BylawsSearchEngine.expandQuery(query);
    if (tokens.isEmpty) {
      return Text(text, style: style);
    }

    // Sort tokens by length descending to match glowing keywords
    tokens.sort((a, b) => b.length.compareTo(a.length));

    // Escape tokens for Regex
    final pattern = tokens
        .map((t) => RegExp.escape(t))
        .where((t) => t.isNotEmpty)
        .join('|');

    if (pattern.isEmpty) {
      return Text(text, style: style);
    }

    final regex = RegExp('\\b($pattern)', caseSensitive: false);

    final List<TextSpan> spans = [];
    int start = 0;

    for (final match in regex.allMatches(text)) {
      if (match.start > start) {
        spans.add(TextSpan(text: text.substring(start, match.start)));
      }
      spans.add(TextSpan(
        text: text.substring(match.start, match.end),
        style: TextStyle(
          backgroundColor: highlightColor,
          fontWeight: FontWeight.bold,
          color: style.color,
        ),
      ));
      start = match.end;
    }

    if (start < text.length) {
      spans.add(TextSpan(text: text.substring(start)));
    }

    return RichText(
      text: TextSpan(
        style: style,
        children: spans,
      ),
    );
  }
}

// ─── App Entry Point ──────────────────────────────────────────────────────────
class MyApp extends StatefulWidget {
  const MyApp({super.key});

  static _MyAppState? of(BuildContext context) =>
      context.findAncestorStateOfType<_MyAppState>();

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  ThemeMode _themeMode = ThemeMode.dark;

  void toggleTheme() {
    setState(() {
      _themeMode = _themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    });
  }

  bool get isDark => _themeMode == ThemeMode.dark;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "FCIT Bylaws Search",
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF5B4FCF),
          brightness: Brightness.light,
        ),
        cardTheme: CardThemeData(
          elevation: 2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF7C6FF7),
          brightness: Brightness.dark,
          surface: const Color(0xFF16162A),
          primary: const Color(0xFF7C6FF7),
          secondary: const Color(0xFF03DAC6),
        ),
        scaffoldBackgroundColor: const Color(0xFF0A0A16),
        cardTheme: CardThemeData(
          color: const Color(0xFF16162A),
          elevation: 4,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
      home: const SplashView(),
    );
  }
}

// ─── Splash Screen View ───────────────────────────────────────────────────────
class SplashView extends StatefulWidget {
  const SplashView({super.key});

  @override
  State<SplashView> createState() => _SplashViewState();
}

class _SplashViewState extends State<SplashView> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: const Interval(0.0, 0.7, curve: Curves.easeIn)),
    );

    _scaleAnimation = Tween<double>(begin: 0.8, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: const Interval(0.0, 0.8, curve: Curves.easeOutBack)),
    );

    _controller.forward();

    // Navigate after 2 seconds
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        Navigator.of(context).pushReplacement(
          PageRouteBuilder(
            pageBuilder: (context, animation, secondaryAnimation) => ChatScreen(
              onThemeToggle: () => MyApp.of(context)?.toggleTheme(),
              isDark: MyApp.of(context)?.isDark ?? true,
            ),
            transitionsBuilder: (context, animation, secondaryAnimation, child) {
              return FadeTransition(opacity: animation, child: child);
            },
            transitionDuration: const Duration(milliseconds: 600),
          ),
        );
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF07070E),
      body: Stack(
        children: [
          // Background glowing spheres
          Positioned(
            top: -120,
            left: -120,
            child: Container(
              width: 320,
              height: 320,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF7C6FF7).withValues(alpha: 0.12),
              ),
            ),
          ),
          Positioned(
            bottom: -120,
            right: -120,
            child: Container(
              width: 320,
              height: 320,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF03DAC6).withValues(alpha: 0.08),
              ),
            ),
          ),
          Center(
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) {
                return FadeTransition(
                  opacity: _fadeAnimation,
                  child: ScaleTransition(
                    scale: _scaleAnimation,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        // Beautiful glowing widget-based logo
                        Container(
                          width: 96,
                          height: 96,
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [Color(0xFF7C6FF7), Color(0xFF03DAC6)],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            borderRadius: BorderRadius.circular(28),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(0xFF7C6FF7).withValues(alpha: 0.35),
                                blurRadius: 24,
                                spreadRadius: 1,
                                offset: const Offset(0, 8),
                              ),
                            ],
                          ),
                          child: const Icon(
                            Icons.school_rounded,
                            color: Colors.white,
                            size: 52,
                          ),
                        ),
                        const SizedBox(height: 24),
                        const Text(
                          "FCIT BYLAWS",
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                            letterSpacing: 4,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          "Accreditation Standards Search",
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.white.withValues(alpha: 0.4),
                            letterSpacing: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Chat Screen ──────────────────────────────────────────────────────────────
class ChatScreen extends StatefulWidget {
  final VoidCallback onThemeToggle;
  final bool isDark;

  const ChatScreen({
    super.key, 
    required this.onThemeToggle, 
    required this.isDark,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final BylawsSearchEngine _engine = BylawsSearchEngine();
  final List<ChatMessage> _messages = [];
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FlutterTts _tts = FlutterTts();
  bool _loading = true;
  ChatMode _chatMode = ChatMode.offlineSearch;
  bool _aiLoading = false;

  static const List<String> _suggestions = [
    "What are the graduation requirements?",
    "Minimum GPA to pass a course?",
    "How many credit hours to graduate?",
    "Academic probation rules",
    "Course withdrawal policy",
    "Grading system and GPA calculation",
  ];

  @override
  void initState() {
    super.initState();
    _engine.load().then((_) => setState(() => _loading = false));
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    _tts.stop();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  int? _extractPageNumber(String text) {
    final match = RegExp(r"\|\s*Page\s*\|\s*(\d+)", caseSensitive: false).firstMatch(text);
    if (match != null) {
      return int.tryParse(match.group(1) ?? "");
    }
    final match2 = RegExp(r"Page\s+(\d+)", caseSensitive: false).firstMatch(text);
    if (match2 != null) {
      return int.tryParse(match2.group(1) ?? "");
    }
    return null;
  }

  Future<void> _sendAiQuery(String query) async {
    setState(() {
      _messages.add(ChatMessage(text: query, isUser: true));
      _aiLoading = true;
    });
    _scrollToBottom();

    try {
      // 1. Get Groq API key from settings
      final groqKey = await AppSettings.getGroqKey();

      if (groqKey.isEmpty) {
        throw Exception(
          'Groq API key is not set.\n'
          'Please open Settings (⚙️) and enter your Groq API key.\n\n'
          'Get a free key from: console.groq.com',
        );
      }

      // 2. Use local BM25 engine to find relevant bylaws sections (RAG)
      final searchResults = _engine.search(query, topK: 5);
      final context = searchResults.isNotEmpty
          ? searchResults.map((r) => r.text).join('\n\n')
          : 'No specific bylaws sections found for this query.';

      // 3. Call Groq API directly (no server needed!)
      const systemPrompt =
          'You are a helpful academic advisor for FCIT (Faculty of Computing and Information Technology). '
          'You answer questions about the faculty bylaws and regulations. '
          'Use the provided context from the official bylaws document to answer accurately. '
          'If the context does not contain enough information, say so honestly. '
          'Be concise, clear, and helpful. You can answer in Arabic or English based on the question language.';

      final httpResponse = await http
          .post(
            Uri.parse(AppSettings.groqEndpoint),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $groqKey',
            },
            body: jsonEncode({
              'model': AppSettings.model,
              'messages': [
                {'role': 'system', 'content': systemPrompt},
                {
                  'role': 'user',
                  'content': 'Context from FCIT Bylaws:\n$context\n\nQuestion: $query',
                },
              ],
              'max_tokens': 1024,
              'temperature': 0.3,
            }),
          )
          .timeout(
            const Duration(seconds: 45),
            onTimeout: () => throw Exception(
              'Request timed out. Please check your internet connection.',
            ),
          );

      if (httpResponse.statusCode != 200) {
        final errorBody = jsonDecode(httpResponse.body);
        final errorMsg = errorBody['error']?['message'] ?? httpResponse.body;
        throw Exception('Groq API error: $errorMsg');
      }

      final data = jsonDecode(httpResponse.body) as Map<String, dynamic>;
      final reply = data['choices']?[0]?['message']?['content'] as String? ??
          'No reply received.';

      setState(() {
        _messages.add(ChatMessage(text: reply, isUser: false, isAi: true));
        _aiLoading = false;
      });
    } catch (e) {
      String errMsg = e.toString();
      if (errMsg.startsWith('Exception: ')) errMsg = errMsg.substring(11);
      setState(() {
        _messages.add(ChatMessage(
          text: '❌ Error: $errMsg',
          isUser: false,
          isAi: true,
        ));
        _aiLoading = false;
      });
    }
    _scrollToBottom();
  }

  void _sendMessage([String? prefilledText]) {
    final query = (prefilledText ?? _controller.text).trim();
    if (query.isEmpty || _loading || _aiLoading) return;
    _controller.clear();

    if (_chatMode == ChatMode.aiAssistant) {
      _sendAiQuery(query);
    } else {
      final results = _engine.search(query, topK: 4);

      setState(() {
        _messages.add(ChatMessage(text: query, isUser: true));
        _messages.add(ChatMessage(
          text: query,
          isUser: false,
          results: results,
          isAi: false,
        ));
      });
      _scrollToBottom();
    }
  }

  Future<void> _speak(String text) async {
    await _tts.stop();
    await _tts.setLanguage("en-US");
    await _tts.speak(text);
  }

  void _showSettingsSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => const AppSettingsSheet(),
    );
  }

  // Beautiful background with slow-bleeding color gradients and radial blobs
  Widget _buildGlowingBackground(BuildContext context, bool isDark) {
    if (!isDark) {
      return Container(
        color: const Color(0xFFF4F4FA),
      );
    }
    return Container(
      color: const Color(0xFF07070E),
      child: Stack(
        children: [
          // Glowing Indigo orb top right
          Positioned(
            top: -100,
            right: -100,
            child: Container(
              width: 380,
              height: 380,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF7C6FF7).withValues(alpha: 0.14),
              ),
            ),
          ),
          // Glowing Cyan orb bottom left
          Positioned(
            bottom: -120,
            left: -120,
            child: Container(
              width: 400,
              height: 400,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF03DAC6).withValues(alpha: 0.09),
              ),
            ),
          ),
          // Blur backdrop
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 100, sigmaY: 100),
              child: Container(color: Colors.transparent),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        titleSpacing: 16,
        flexibleSpace: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: Container(color: Colors.transparent),
          ),
        ),
        title: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [cs.primary, cs.secondary],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(11),
                boxShadow: [
                  BoxShadow(
                    color: cs.primary.withValues(alpha: 0.25),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: const Icon(Icons.school_rounded, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 11),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("FCIT Bylaws", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                Text(
                  _loading
                      ? "Loading bylaws..."
                      : (_chatMode == ChatMode.offlineSearch
                          ? "✓ Offline Search active"
                          : "⚡ AI Chatbot direct mode"),
                  style: TextStyle(
                      fontSize: 10.5,
                      color: _loading
                          ? cs.onSurface.withValues(alpha: 0.4)
                          : cs.secondary,
                      fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(_chatMode == ChatMode.offlineSearch
                ? Icons.smart_toy_outlined
                : Icons.manage_search_rounded),
            onPressed: () {
              setState(() {
                _chatMode = _chatMode == ChatMode.offlineSearch
                    ? ChatMode.aiAssistant
                    : ChatMode.offlineSearch;
              });
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(_chatMode == ChatMode.offlineSearch
                      ? "Switched to Offline Search"
                      : "Switched to direct AI Chatbot"),
                  duration: const Duration(seconds: 2),
                ),
              );
            },
            tooltip: _chatMode == ChatMode.offlineSearch ? "Use AI Chatbot" : "Use Offline Search",
          ),
          IconButton(
            icon: Icon(isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined),
            onPressed: () => MyApp.of(context)?.toggleTheme(),
            tooltip: "Toggle Theme",
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: _showSettingsSheet,
            tooltip: "Settings",
          ),
          if (_messages.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: () => setState(() => _messages.clear()),
              tooltip: "Clear History",
            ),
        ],
      ),
      body: Stack(
        children: [
          _buildGlowingBackground(context, isDark),
          SafeArea(
            child: Column(
              children: [
                Expanded(
                  child: _loading
                      ? _buildLoadingView(cs)
                      : _messages.isEmpty
                          ? _buildWelcomeView(cs)
                          : _buildChatList(cs),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: _buildInputBar(cs),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingView(ColorScheme cs) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 48,
            height: 48,
            child: CircularProgressIndicator(strokeWidth: 3, color: cs.primary),
          ),
          const SizedBox(height: 20),
          Text(
            "Loading FCIT Bylaws...",
            style: TextStyle(color: isDark ? Colors.white60 : Colors.black54, fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _buildWelcomeView(ColorScheme cs) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      children: [
        const SizedBox(height: 20),
        Center(
          child: Column(
            children: [
              Container(
                width: 90,
                height: 90,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [cs.primary, cs.secondary],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: cs.primary.withValues(alpha: 0.3),
                      blurRadius: 16,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: const Icon(Icons.school_rounded, size: 48, color: Colors.white),
              ),
              const SizedBox(height: 20),
              Text(
                "FCIT Bylaws Explorer",
                style: TextStyle(
                  fontSize: 24, 
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : Colors.black87,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                "Browse and query all Faculty regulations instantly on your device.\nUse the offline search or enable AI assistant in settings.",
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: isDark ? Colors.white60 : Colors.black54,
                    height: 1.5,
                    fontSize: 13.5),
              ),
            ],
          ),
        ),
        const SizedBox(height: 28),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _featureChip(cs, Icons.wifi_off, "100% Offline"),
            const SizedBox(width: 8),
            _featureChip(cs, Icons.auto_awesome, "Direct Gemini"),
            const SizedBox(width: 8),
            _featureChip(cs, Icons.lock_outline, "Private"),
          ],
        ),
        const SizedBox(height: 32),
        Text(
          "Quick search topics:",
          style: TextStyle(
              fontWeight: FontWeight.bold,
              color: isDark ? Colors.white70 : Colors.black87,
              fontSize: 14),
        ),
        const SizedBox(height: 12),
        ..._suggestions.map((s) => _buildSuggestionTile(s, cs)),
      ],
    );
  }

  Widget _featureChip(ColorScheme cs, IconData icon, String label) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E38).withValues(alpha: 0.5) : cs.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark ? const Color(0xFF7C6FF7).withValues(alpha: 0.15) : cs.primary.withValues(alpha: 0.15),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: cs.primary),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(fontSize: 11, color: isDark ? Colors.white70 : cs.primary, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }

  Widget _buildSuggestionTile(String text, ColorScheme cs) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () => _sendMessage(text),
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            border: Border.all(
              color: isDark ? const Color(0xFF7C6FF7).withValues(alpha: 0.15) : cs.outline.withValues(alpha: 0.2),
            ),
            borderRadius: BorderRadius.circular(16),
            color: isDark ? const Color(0xFF16162A).withValues(alpha: 0.5) : cs.surface.withValues(alpha: 0.6),
          ),
          child: Row(
            children: [
              Icon(Icons.search_rounded, size: 18, color: cs.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  text, 
                  style: TextStyle(
                    fontSize: 14,
                    color: isDark ? Colors.white.withValues(alpha: 0.8) : Colors.black87,
                  ),
                ),
              ),
              Icon(Icons.north_west_rounded, size: 14, color: isDark ? Colors.white30 : Colors.black26),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildChatList(ColorScheme cs) {
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      itemCount: _messages.length + (_aiLoading ? 1 : 0),
      itemBuilder: (_, i) {
        if (i == _messages.length) {
          return _buildThinkingBubble(cs);
        }
        final msg = _messages[i];
        if (msg.isUser) {
          return _buildUserBubble(msg, cs);
        } else if (msg.isAi) {
          return _buildAiResponseBubble(msg, cs);
        } else {
          return _buildResultCard(msg, cs);
        }
      },
    );
  }

  Widget _buildThinkingBubble(ColorScheme cs) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF16162A).withValues(alpha: 0.7) : Colors.white.withValues(alpha: 0.9),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(4),
            topRight: Radius.circular(18),
            bottomLeft: Radius.circular(18),
            bottomRight: Radius.circular(18),
          ),
          border: Border.all(
            color: isDark ? const Color(0xFF7C6FF7).withValues(alpha: 0.15) : const Color(0xFF5B4FCF).withValues(alpha: 0.1),
            width: 1.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            WidgetToAnimateGlow(
              child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              "Thinking...",
              style: TextStyle(fontSize: 13, color: isDark ? Colors.white60 : Colors.black54),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAiResponseBubble(ChatMessage msg, ColorScheme cs) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.85),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF16162A).withValues(alpha: 0.7) : Colors.white.withValues(alpha: 0.9),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(4),
            topRight: Radius.circular(18),
            bottomLeft: Radius.circular(18),
            bottomRight: Radius.circular(18),
          ),
          border: Border.all(
            color: isDark ? const Color(0xFF7C6FF7).withValues(alpha: 0.15) : const Color(0xFF5B4FCF).withValues(alpha: 0.1),
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.15),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.auto_awesome_rounded, size: 15, color: cs.secondary),
                const SizedBox(width: 6),
                Text(
                  "AI Assistant",
                  style: TextStyle(fontSize: 12, color: cs.secondary, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: () => _speak(msg.text),
                  child: Icon(Icons.volume_up_outlined, size: 16, color: cs.primary),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              msg.text,
              style: TextStyle(fontSize: 14, color: isDark ? const Color(0xFFE0E0E0) : Colors.black87, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUserBubble(ChatMessage msg, ColorScheme cs) {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF7C6FF7), Color(0xFF5A4FCF)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(18),
            topRight: Radius.circular(18),
            bottomLeft: Radius.circular(18),
            bottomRight: Radius.circular(4),
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF7C6FF7).withValues(alpha: 0.3),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Text(msg.text, style: const TextStyle(color: Colors.white, fontSize: 14)),
      ),
    );
  }

  Widget _buildResultCard(ChatMessage msg, ColorScheme cs) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (msg.results.isEmpty) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.85),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF381C1C).withValues(alpha: 0.5) : const Color(0xFFFFDADA),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(4),
              topRight: Radius.circular(18),
              bottomLeft: Radius.circular(18),
              bottomRight: Radius.circular(18),
            ),
            border: Border.all(
              color: isDark ? const Color(0xFFE57373).withValues(alpha: 0.2) : const Color(0xFFFF8A80),
              width: 1.5,
            ),
          ),
          child: Row(
            children: [
              Icon(Icons.search_off_rounded, color: isDark ? const Color(0xFFE57373) : const Color(0xFFC62828), size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  "No results found in the bylaws for: \"${msg.text}\"\n\nTry different keywords.",
                  style: TextStyle(color: isDark ? const Color(0xFFE57373) : const Color(0xFFC62828), fontSize: 13.5),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(top: 4, bottom: 10),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.95),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 8),
              child: Row(
                children: [
                  Icon(Icons.auto_awesome_rounded, size: 14, color: cs.secondary),
                  const SizedBox(width: 6),
                  Text(
                    "Found ${msg.results.length} relevant section${msg.results.length > 1 ? 's' : ''}",
                    style: TextStyle(fontSize: 12, color: cs.secondary, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
            ...msg.results.asMap().entries.map((entry) {
              final i = entry.key;
              final r = entry.value;
              return _buildSectionCard(r, i, cs, msg.text);
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionCard(SearchResult result, int index, ColorScheme cs, String query) {
    final relevance = min(result.score / 10.0, 1.0);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF16162A).withValues(alpha: 0.6) : const Color(0xFFFFFFFF).withValues(alpha: 0.8),
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(index == 0 ? 4 : 16),
          topRight: const Radius.circular(18),
          bottomLeft: const Radius.circular(16),
          bottomRight: const Radius.circular(18),
        ),
        border: Border.all(
          color: isDark ? const Color(0xFF7C6FF7).withValues(alpha: 0.15) : const Color(0xFF5B4FCF).withValues(alpha: 0.12),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 8,
              offset: const Offset(0, 4))
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 10),
            child: HighlightText(
              text: result.text,
              query: query,
              style: TextStyle(fontSize: 13.5, color: isDark ? Colors.white.withValues(alpha: 0.9) : Colors.black87, height: 1.55),
              highlightColor: cs.primary.withValues(alpha: 0.2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 12, 12),
            child: Row(
              children: [
                Container(
                  width: 60,
                  height: 4,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(2),
                    color: isDark ? Colors.white12 : Colors.black12,
                  ),
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: relevance.clamp(0.1, 1.0),
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(2),
                        color: cs.primary,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  "${(relevance * 100).round()}% match",
                  style: TextStyle(fontSize: 11, color: isDark ? Colors.white38 : Colors.black45),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: () => _speak(result.text),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: cs.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.volume_up_rounded, size: 13, color: cs.primary),
                        const SizedBox(width: 4),
                        Text("Read", style: TextStyle(fontSize: 11, color: cs.primary, fontWeight: FontWeight.w500)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInputBar(ColorScheme cs) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF16162A).withValues(alpha: 0.85) : const Color(0xFFFFFFFF).withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(
          color: isDark ? const Color(0xFF7C6FF7).withValues(alpha: 0.2) : const Color(0xFF5B4FCF).withValues(alpha: 0.15),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              maxLines: null,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _sendMessage(),
              enabled: !_loading,
              style: TextStyle(fontSize: 14, color: isDark ? Colors.white : Colors.black87),
              decoration: InputDecoration(
                hintText: _loading
                    ? "Loading regulations..."
                    : (_chatMode == ChatMode.offlineSearch
                        ? "Search bylaws (GPA, graduation...)"
                        : "Ask AI Assistant about bylaws..."),
                hintStyle: TextStyle(fontSize: 13, color: isDark ? Colors.white30 : Colors.black38),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                filled: false,
                prefixIcon: Icon(Icons.search_rounded, color: isDark ? Colors.white30 : Colors.black38, size: 20),
              ),
            ),
          ),
          const SizedBox(width: 4),
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [cs.primary, cs.secondary],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: [
                BoxShadow(
                  color: cs.primary.withValues(alpha: 0.3),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: IconButton(
              onPressed: _loading ? null : () => _sendMessage(),
              icon: Icon(
                _chatMode == ChatMode.offlineSearch ? Icons.search_rounded : Icons.send_rounded,
                color: Colors.white,
                size: 20,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// A simple widget to bypass indicator warnings
class WidgetToAnimateGlow extends StatelessWidget {
  final Widget child;
  const WidgetToAnimateGlow({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return child;
  }
}

// ─── Settings Modal Sheet Widget ──────────────────────────────────────────────
class AppSettingsSheet extends StatefulWidget {
  const AppSettingsSheet({super.key});

  @override
  State<AppSettingsSheet> createState() => _AppSettingsSheetState();
}

class _AppSettingsSheetState extends State<AppSettingsSheet> {
  final _urlController = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final key = await AppSettings.getGroqKey();
    setState(() {
      _urlController.text = key;
    });
  }

  Future<void> _saveSettings() async {
    final key = _urlController.text.trim();
    if (key.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter your Groq API key.'), backgroundColor: Colors.redAccent),
      );
      return;
    }
    if (!key.startsWith('gsk_')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invalid key. Groq keys start with "gsk_"'), backgroundColor: Colors.orange),
      );
      return;
    }
    setState(() => _saving = true);
    await AppSettings.setGroqKey(key);
    setState(() => _saving = false);
    if (mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Groq API key saved! AI Assistant is ready ✅'),
          backgroundColor: Color(0xFF5B4FCF),
        ),
      );
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF16162A) : Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border.all(
            color: isDark
                ? const Color(0xFF7C6FF7).withValues(alpha: 0.15)
                : const Color(0xFF5B4FCF).withValues(alpha: 0.1),
            width: 1.5,
          ),
        ),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Handle bar
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: isDark ? Colors.white24 : Colors.black12,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 18),
            // Title row
            Row(
              children: [
                Icon(Icons.vpn_key_rounded, color: cs.primary),
                const SizedBox(width: 10),
                Text(
                  'AI Settings',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Info card
            Container(
              margin: const EdgeInsets.only(top: 4, bottom: 16),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: cs.primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: cs.primary.withValues(alpha: 0.2)),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline_rounded, size: 16, color: cs.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'The app uses Groq AI directly — no server needed! Get a free API key from console.groq.com',
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? Colors.white60 : Colors.black54,
                        height: 1.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Groq API Key field
            Text(
              'Groq API Key',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.white70 : Colors.black54,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _urlController,
              keyboardType: TextInputType.visiblePassword,
              obscureText: true,
              style: TextStyle(color: isDark ? Colors.white : Colors.black87),
              decoration: InputDecoration(
                filled: true,
                fillColor: isDark ? const Color(0xFF0B0B16) : const Color(0xFFF3F3FA),
                hintText: 'gsk_xxxxxxxxxxxxxxxxxxxxxxxx',
                hintStyle: TextStyle(color: isDark ? Colors.white30 : Colors.black38),
                prefixIcon: Icon(Icons.key_rounded, color: cs.primary),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: cs.primary, width: 1.5),
                ),
              ),
            ),
            const SizedBox(height: 24),
            // Save button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _saving ? null : _saveSettings,
                style: ElevatedButton.styleFrom(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  backgroundColor: cs.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: _saving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('Save API Key'),
              ),
            ),
            const SizedBox(height: 16),
            Center(
              child: GestureDetector(
                onTap: () {},
                child: Text(
                  'Get a FREE Groq key → console.groq.com',
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.primary,
                    decoration: TextDecoration.underline,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
