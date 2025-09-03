// lib/main.dart
import 'package:flutter/material.dart';
import 'package:flutter_brotcattle/cow_feed_page.dart';
import 'package:flutter_brotcattle/inventory_page.dart';
import 'package:universal_html/html.dart' as html;

import 'api_service.dart';
import 'milk_production.dart'; // expects MilkProductionPage({ required ApiService api, required String token }) or similar
import 'animal_central.dart'; // expects AnimalCentralPage({ required String token })
import 'net_per_animal_page.dart'; // the page we added earlier

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Brot Cattle',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        appBarTheme: const AppBarTheme(elevation: 2),
        scaffoldBackgroundColor: Colors.grey[100],
      ),
      home: const LoginHandler(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class LoginHandler extends StatefulWidget {
  const LoginHandler({super.key});
  @override
  State<LoginHandler> createState() => _LoginHandlerState();
}

class _LoginHandlerState extends State<LoginHandler> {
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _handleLogin();
  }

  Future<void> _handleLogin() async {
    try {
      final uri = Uri.base;
      final fragment = uri.fragment;
      final token = fragment.startsWith('token=')
          ? fragment.replaceFirst('token=', '')
          : '';

      debugPrint(
        'LoginHandler fragment="$fragment" tokenPresent=${token.isNotEmpty}',
      );

      if (token.isNotEmpty) {
        final apiService = ApiService(token);
        if (apiService.isTokenExpired()) {
          setState(() {
            _isLoading = false;
            _error =
                'Your login link has expired. Please open the link from the Telegram bot again to get a fresh link.';
          });
          return;
        }

        try {
          html.window.history.replaceState(
            null,
            '',
            html.window.location.pathname,
          );
        } catch (e) {
          debugPrint('Failed to clear fragment: $e');
        }

        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (context) => HomeTabs(token: token)),
        );
        return;
      }

      setState(() {
        _error =
            'No authentication token provided. Please open this app from the Telegram bot.';
        _isLoading = false;
      });
    } catch (e, st) {
      debugPrint('LoginHandler error: $e\n$st');
      setState(() {
        _error = 'Failed to authenticate: $e';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: _isLoading
            ? const CircularProgressIndicator()
            : _error != null
                ? Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.error_outline,
                          size: 48,
                          color: Colors.red,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                      ],
                    ),
                  )
                : const Text('Please open this app from the Telegram bot'),
      ),
    );
  }
}

class HomeTabs extends StatelessWidget {
  final String token;
  const HomeTabs({super.key, required this.token});

  @override
  Widget build(BuildContext context) {
    final apiService = ApiService(token);

    return DefaultTabController(
      length: 5, // <-- fixed to match the number of tabs/pages
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Brot Cattle'),
          bottom: TabBar(
            isScrollable: true, // optional, nicer with many tabs
            tabs: const [
              Tab(text: 'Milk Production'),
              Tab(text: 'Animals'),
              Tab(text: 'Net per Animal'),
              //Tab(text: 'Fill Net'),
              Tab(text: 'Cow Feed'),
              Tab(text: 'Inventory'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            MilkProductionPage(api: apiService, token: token),
            AnimalCentralPage(token: token),
            NetPerAnimalPage(apiService: apiService),
            //FillNetPage(apiService: apiService),
            CowFeedPage(apiService: apiService),
            InventoryPage(apiService: apiService),
          ],
        ),
      ),
    );
  }
}


/*scroll without
import 'package:flutter/material.dart';
import 'package:universal_html/html.dart' as html;
import 'package:flutter/foundation.dart' show debugPrint;
import 'api_service.dart';
import 'milk_production.dart';
import 'animal_central.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Brot Cattle',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        appBarTheme: const AppBarTheme(elevation: 2),
        scaffoldBackgroundColor: Colors.grey[100],
      ),
      home: const LoginHandler(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class LoginHandler extends StatefulWidget {
  const LoginHandler({super.key});
  @override
  State<LoginHandler> createState() => _LoginHandlerState();
}

class _LoginHandlerState extends State<LoginHandler> {
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _handleLogin();
  }

  Future<void> _handleLogin() async {
    try {
      final uri = Uri.base;
      final fragment = uri.fragment;
      final token = fragment.startsWith('token=')
          ? fragment.replaceFirst('token=', '')
          : '';

      debugPrint(
        'LoginHandler fragment="$fragment" tokenPresent=${token.isNotEmpty}',
      );

      if (token.isNotEmpty) {
        final apiService = ApiService(token);
        if (apiService.isTokenExpired()) {
          setState(() {
            _isLoading = false;
            _error =
                'Your login link has expired. Please open the link from the Telegram bot again to get a fresh link.';
          });
          return;
        }

        try {
          html.window.history.replaceState(
            null,
            '',
            html.window.location.pathname,
          );
        } catch (e) {
          debugPrint('Failed to clear fragment: $e');
        }

        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (context) => HomeTabs(token: token)),
        );
        return;
      }

      setState(() {
        _error =
            'No authentication token provided. Please open this app from the Telegram bot.';
        _isLoading = false;
      });
    } catch (e, st) {
      debugPrint('LoginHandler error: $e\n$st');
      setState(() {
        _error = 'Failed to authenticate: $e';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: _isLoading
            ? const CircularProgressIndicator()
            : _error != null
            ? Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      size: 48,
                      color: Colors.red,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                  ],
                ),
              )
            : const Text('Please open this app from the Telegram bot'),
      ),
    );
  }
}

class HomeTabs extends StatelessWidget {
  final String token;
  const HomeTabs({super.key, required this.token});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Brot Cattle'),
          bottom: TabBar(
            labelColor: Theme.of(context).colorScheme.primary,
            unselectedLabelColor: Theme.of(
              context,
            ).colorScheme.onSurfaceVariant,
            indicatorColor: Theme.of(context).colorScheme.primary,
            tabs: const [
              Tab(text: 'Milk Production'),
              Tab(text: 'Animals'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            MilkProductionPage(token: token),
            AnimalCentralPage(token: token),
          ],
        ),
      ),
    );
  }
}
*/
