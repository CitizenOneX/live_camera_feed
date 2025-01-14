import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:simple_frame_app/frame_vision_app.dart';
import 'package:simple_frame_app/simple_frame_app.dart';
import 'package:simple_frame_app/tx/plain_text.dart';

void main() => runApp(const MainApp());

final _log = Logger("MainApp");

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  MainAppState createState() => MainAppState();
}

class MainAppState extends State<MainApp> with SimpleFrameAppState, FrameVisionAppState {
  // main state of camera streaming on/off
  bool _processing = false;

  // the image and metadata to show
  Image? _image;
  ImageMetadata? _imageMeta;

  MainAppState() {
    Logger.root.level = Level.INFO;
    Logger.root.onRecord.listen((record) {
      debugPrint('${record.level.name}: ${record.time}: ${record.loggerName}: ${record.message}');
    });
  }

  @override
  void initState() {
    super.initState();

    // kick off the connection to Frame and start the app if possible
    tryScanAndConnectAndStart(andRun: true);
  }

  @override
  Future<void> onRun() async {
    // initial message to display when running
    await frame!.sendMessage(
      TxPlainText(
        msgCode: 0x0a,
        text: '2-Tap: start or stop stream'
      )
    );
  }

  @override
  Future<void> onCancel() async {
    // no app-specific cleanup required here
  }

  @override
  Future<void> onTap(int taps) async {
    switch (taps) {
      case 2:
        // check if there's processing in progress already and drop the request if so
        if (!_processing) {
          // start new vision capture
          // asynchronously kick off the capture/processing pipeline
          startStreaming();
        }
        else {
          // state moves to stopping streaming after current image
          // processing completes
          stopStreaming();
        }
        break;
      default:
    }
  }

  /// Long-running loop that continues requesting photos
  /// and processing them until _processing is set to false
  Future<void> startStreaming() async {
    _log.fine('start streaming');
    _processing = true;
    while (_processing) {
      // synchronously call the capture and processing (just display) of each photo
      await capture().then(process);
    }
  }

  void stopStreaming() {
    _log.fine('stop streaming');
    _processing = false;
  }

  /// The vision pipeline to run when a photo is captured
  /// Which in this case is just displaying
  FutureOr<void> process((Uint8List, ImageMetadata) photo) async {
    var imageData = photo.$1;
    var meta = photo.$2;

    setState(() {
      _image = Image.memory(imageData, gaplessPlayback: true,);
      _imageMeta = meta;
    });
  }

  /// cancel the current photo
  @override
  Future<void> cancel() async {
    currentState = ApplicationState.ready;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Frame Live Camera Feed',
      theme: ThemeData.dark(),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Frame Live Camera Feed'),
          actions: [getBatteryWidget()]
        ),
        drawer: getCameraDrawer(),
        onDrawerChanged: (isOpened) {
          if (isOpened) {
            // if the user opens the camera settings, stop streaming
            _processing = false;
          }
          else {
            // if the user closes the camera settings, send the updated settings to Frame
            sendExposureSettings();
          }
        },
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: [
                  _image ?? Container(),
                  const Divider(),
                  if (_imageMeta != null) ImageMetadataWidget(meta: _imageMeta!),
                ],
              )
            ),
            const Divider(),
          ],
        ),
        floatingActionButton: getFloatingActionButtonWidget(const Icon(Icons.camera_alt), const Icon(Icons.cancel)),
        persistentFooterButtons: getFooterButtonsWidget(),
      ),
    );
  }
}
