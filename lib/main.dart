import 'package:material_ui/material_ui.dart';

import 'state/app_state.dart';
import 'ui/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final state = AppState();
  runApp(DomLabApp(state: state));
  await state.init();
}

class DomLabApp extends StatelessWidget {
  const DomLabApp({super.key, required this.state});

  final AppState state;

  // Colori Dom Studio.
  static const Color bluCasa = Color(0xFF1D3A8A);
  static const Color bluCasaChiaro = Color(0xFF8FA9F2);
  static const Color aranciTetto = Color(0xFFF28C38);
  static const Color carta = Color(0xFFFFF8F0);
  static const Color bluNotte = Color(0xFF121621);

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: state,
      child: MaterialApp(
        title: 'D. Dom Lab',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: bluCasa,
            primary: bluCasa,
            tertiary: aranciTetto,
            surface: carta,
          ),
          fontFamily: 'Sora',
          scaffoldBackgroundColor: carta,
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: bluCasa,
            brightness: Brightness.dark,
            primary: bluCasaChiaro,
            tertiary: aranciTetto,
            surface: bluNotte,
          ),
          fontFamily: 'Sora',
          scaffoldBackgroundColor: bluNotte,
          useMaterial3: true,
        ),
        home: const HomeScreen(),
      ),
    );
  }
}
