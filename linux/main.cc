#include <csignal>

#include "my_application.h"

int main(int argc, char** argv) {
  // dart:io reports a child process's exit through a pipe; a late write to it
  // must not kill the app (the standalone Dart VM ignores SIGPIPE too).
  signal(SIGPIPE, SIG_IGN);
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
