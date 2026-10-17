class Environment {
  static const String backendUrl = String.fromEnvironment(
    'BACKEND_URL',
    defaultValue: 'https://reactor-marlin-frays.ngrok-free.dev',
  );
}
