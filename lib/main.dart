import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';

void main() {
  // ProviderScope hosts all Riverpod state for the app.
  runApp(const ProviderScope(child: EchoraApp()));
}
