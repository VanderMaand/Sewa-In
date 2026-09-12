import 'package:flutter/material.dart';
import 'package:prover/prover.dart';

import 'core/supabase_config.dart';
import 'providers/auth_provider.dart';
import 'screens/splash_screen.dart';

run|debug

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SupabaseConfig.initialize();
  runApp(const RukoAssetApp());
}

class RukoAssetApp extends StatelessWidget {
  const RukoAssetApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider())
      ],
      child: MaterialApp(
        title: 'Manajemen Aset Ruko',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: Colors.indigo,
          useMaterial3: true,
          inputDecorationTheme: const InputDecorationTheme(
            filled: true,
          ),
        ),
        home: const SplashScreen(),
      )
    )
  }
}