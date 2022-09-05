class LeakItem {
  LeakItem(this.url, {this.status});

  final String url;
  LeakStatus? status;

  static List<String> prePopulatedUrls() {
    return [
      'https://console.firebase.google.com',
      'https://developer.android.com',
      'https://storage.googleapis.com/dartlang-pub-public-packages/packages/live_event-0.0.1.tar.gz',
      'https://dl.google.com/dl/android/maven2/com/android/tools/build/gradle/4.1.3/gradle-4.1.3.pom',
    ];
  }
}

enum LeakStatus { failed, passed, loading }
