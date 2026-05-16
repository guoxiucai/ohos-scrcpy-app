import 'package:flutter/material.dart';

import 'state/app_state.dart';
import 'ui/mirror_view.dart';
import 'ui/sidebar.dart';
import 'ui/split_view.dart';
import 'ui/terminal_drawer.dart';
import 'ui/theme.dart';
import 'ui/top_bar.dart';
import 'ui/vertical_split.dart';

class App extends StatefulWidget {
  const App({super.key});

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> {
  final AppState state = AppState();

  @override
  void initState() {
    super.initState();
    state.addListener(_onChange);
    WidgetsBinding.instance.addPostFrameCallback((_) => state.refreshDevices());
  }

  void _onChange() => setState(() {});

  @override
  void dispose() {
    state.removeListener(_onChange);
    state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mainArea = SplitView(
      left: MirrorView(state: state),
      right: Sidebar(state: state),
    );

    return MaterialApp(
      title: '',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      theme: buildAppTheme(),
      darkTheme: buildAppTheme(),
      home: Scaffold(
        backgroundColor: AppColors.bg,
        body: Column(
          children: [
            TopBar(state: state),
            Expanded(
              child: VerticalSplit(
                top: mainArea,
                bottom: state.terminalOpen ? TerminalDrawer(state: state) : null,
                bottomHeight: state.terminalHeight,
                onResize: state.setTerminalHeight,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
