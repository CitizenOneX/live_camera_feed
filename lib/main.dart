import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:frame_msg/rx/auto_exp_result.dart';
import 'package:logging/logging.dart';
import 'package:simple_frame_app/frame_vision_app.dart';
import 'package:simple_frame_app/simple_frame_app.dart';
import 'package:frame_msg/tx/plain_text.dart';

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

  // auto exposure result stream
  final RxAutoExpResult _rxAutoExpResult = RxAutoExpResult();
  StreamSubscription<AutoExpResult>? _autoExpResultSubs;
  AutoExpResult? _autoExpResult;

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
    // set up receive handler for auto exposure results stream
    // TODO put the values into a state variable
    _autoExpResultSubs?.cancel();
    _autoExpResultSubs = _rxAutoExpResult.attach(frame!.dataResponse).listen((autoExpResult) {
      // update the UI with the latest auto exposure result
      setState(() {
        _autoExpResult = autoExpResult;
      });
      _log.fine('auto exposure result: $autoExpResult');
    },);

    // initial message to display when running
    final text = TxPlainText(text: '2-Tap: start or stop stream');

    await frame!.sendMessage(0x0a, text.pack());
  }

  @override
  Future<void> onCancel() async {
    // cancel the auto exposure result stream
    _autoExpResultSubs?.cancel();

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
                  if (_autoExpResult != null) AutoExpResultWidget(result: _autoExpResult!),
                  const Divider(),
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

class AutoExpResultWidget extends StatelessWidget {
  final AutoExpResult result;
  final TextStyle dataStyle = const TextStyle(fontSize: 10, fontFamily: 'helvetica');

  const AutoExpResultWidget({super.key, required this.result});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8.0),
      decoration: BoxDecoration(
        color: Colors.grey[800],
        borderRadius: BorderRadius.circular(5.0),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Error: ${result.error.toStringAsFixed(2)}', style: dataStyle),
                  Text('RGain: ${result.redGain.toStringAsFixed(2)}', style: dataStyle),
                ],
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Shutter: ${result.shutter.toInt()}', style: dataStyle),
                  Text('GGain: ${result.greenGain.toStringAsFixed(2)}', style: dataStyle),
                ],
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Analog Gain: ${result.analogGain.toInt()}', style: dataStyle),
                  Text('BGain: ${result.blueGain.toStringAsFixed(2)}', style: dataStyle),
                ],
              ),
            ],
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Divider(),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                          'CW Average: ${result.brightness.centerWeightedAverage.toStringAsFixed(2)}',
                          style: dataStyle),
                      Text(
                          'Matrix: [${result.brightness.matrix.r.toStringAsFixed(2)},'
                          '${result.brightness.matrix.g.toStringAsFixed(2)},'
                          '${result.brightness.matrix.b.toStringAsFixed(2)},'
                          '${result.brightness.matrix.average.toStringAsFixed(2)}]',
                          style: dataStyle),
                    ],
                  ),
                  const SizedBox(width: 16), // Add spacing between columns
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                          'Scene: ${result.brightness.scene.toStringAsFixed(2)}',
                          style: dataStyle),
                      Text(
                          'Spot: [${result.brightness.spot.r.toStringAsFixed(2)},'
                          '${result.brightness.spot.g.toStringAsFixed(2)},'
                          '${result.brightness.spot.b.toStringAsFixed(2)},'
                          '${result.brightness.spot.average.toStringAsFixed(2)}]',
                          style: dataStyle)
                          ,
                    ],
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}
