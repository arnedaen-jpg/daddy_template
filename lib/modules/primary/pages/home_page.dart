import 'package:flutter/material.dart';
import '../../../config/app_config.dart';
import '../../../services/config_service.dart';

/// 主要模式首页
/// 这是用于 App Store 审核的页面
/// 开发者可以自由发挥，设计一个能通过审核的应用
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('我的应用'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.apps,
              size: 80,
              color: Colors.blue,
            ),
            const SizedBox(height: 20),
            const Text(
              '欢迎使用',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              '主要模式',
              style: TextStyle(
                fontSize: 16,
                color: Colors.grey,
              ),
            ),
            const SizedBox(height: 30),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 40),
              child: Text(
                '请在此处开发您的功能\n确保符合 App Store 审核规范',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.grey,
                ),
              ),
            ),
            // 调试按钮：仅在 debug 模式下显示
            if (AppConfig.debugMode) ...[
              const SizedBox(height: 40),
              ElevatedButton.icon(
                onPressed: () async {
                  // 使用统一的切换接口（包含次要模块初始化）
                  await ConfigService().switchToSecondary();
                  if (context.mounted) {
                    Navigator.of(context).pushReplacementNamed('/home');
                  }
                },
                icon: const Icon(Icons.swap_horiz),
                label: const Text('切换模式'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
