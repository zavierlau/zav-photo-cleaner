import 'package:flutter/material.dart';

import 'pages/home_page.dart';
import 'theme.dart';

void main() {
  runApp(const PhotoCleanerApp());
}

class PhotoCleanerApp extends StatelessWidget {
  const PhotoCleanerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '相片清理',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      home: const HomePage(),
    );
  }
}