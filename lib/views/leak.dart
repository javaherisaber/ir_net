import 'package:flutter/material.dart';
import 'package:ir_net/data/leak_item.dart';
import 'package:ir_net/main.dart';
import 'package:ir_net/views/kerio_login.dart';
import 'package:touch_mouse_behavior/touch_mouse_behavior.dart';
import 'package:url_launcher/url_launcher.dart';

class LeakView extends StatefulWidget {
  const LeakView({super.key});

  @override
  State<LeakView> createState() => _LeakViewState();
}

class _LeakViewState extends State<LeakView> {
  late TextEditingController textInputController;

  @override
  void initState() {
    textInputController = TextEditingController();
    bloc.clearLeakInput.listen((_) {
      textInputController.clear();
    });
    super.initState();
  }

  @override
  void dispose() {
    textInputController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Text('Leak detection'),
        const SizedBox(height: 16),
        SizedBox(
          width: 400,
          child: input(),
        ),
        const SizedBox(height: 16),
        items(),
        const KerioLoginView()
      ],
    );
  }

  Widget items() {
    return StreamBuilder<List<LeakItem>>(
      stream: bloc.leakChecklist,
      builder: (context, snapshot) {
        final data = snapshot.data;
        if (data == null) {
          return const SizedBox.shrink();
        }
        return SizedBox(
          width: 400,
          height: 250,
          child: TouchMouseScrollable(
            child: ListView.builder(
              itemCount: data.length,
              itemBuilder: (context, index) {
                return item(data[index]);
              },
            ),
          ),
        );
      },
    );
  }

  Widget item(LeakItem item) {
    return InkWell(
      onTap: () {
        launchUrl(Uri.parse(item.url));
      },
      child: Container(
        width: 400,
        decoration: const BoxDecoration(
          shape: BoxShape.rectangle,
          color: Colors.black12,
          borderRadius: BorderRadius.all(Radius.circular(4)),
        ),
        padding: const EdgeInsets.all(8),
        margin: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            if (item.status == LeakStatus.failed)
              const Icon(Icons.remove_circle_outline, color: Colors.red),
            if (item.status == LeakStatus.passed) const Icon(Icons.check, color: Colors.green),
            if (item.status == LeakStatus.loading)
              const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(),
              ),
            const SizedBox(width: 8),
            Expanded(
                child: Text(
              item.url,
              style: const TextStyle(color: Colors.blueAccent),
            )),
            IconButton(
              onPressed: () => bloc.onDeleteLeakItemClick(item),
              icon: Icon(
                Icons.highlight_remove_outlined,
                color: Colors.red.withAlpha(80),
              ),
            )
          ],
        ),
      ),
    );
  }

  Widget input() {
    return TextField(
      controller: textInputController,
      onChanged: bloc.onLeakInputChanged,
      onSubmitted: (_) => bloc.onAddLeakItemClick(),
      decoration: InputDecoration(
        focusedBorder: const OutlineInputBorder(
          borderSide: BorderSide(color: Colors.green),
        ),
        enabledBorder: const OutlineInputBorder(
          borderSide: BorderSide(color: Colors.blue),
        ),
        hintText: 'https://developer.google.com',
        hintStyle: const TextStyle(color: Colors.black38),
        suffixIcon: IconButton(onPressed: bloc.onAddLeakItemClick, icon: const Icon(Icons.add)),
      ),
    );
  }
}
