# Linux Notification Icons

This directory contains PNG versions of the ICO files used by the Windows version of the application.

For Linux compatibility, please convert the following ICO files to PNG format using ImageMagick or another tool:

- loading.ico → loading.png
- offline.ico → offline.png
- network_error.ico → network_error.png
- globe.ico → globe.png
- iran.ico → iran.png
- notification.ico → notification.png

You can convert them using ImageMagick with the following command:

```bash
convert assets/loading.ico assets/linux/loading.png
convert assets/offline.ico assets/linux/offline.png
convert assets/network_error.ico assets/linux/network_error.png
convert assets/globe.ico assets/linux/globe.png
convert assets/iran.ico assets/linux/iran.png
```

After conversion, place the PNG files in this directory.
