import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'camera.dart';
import 'image_data_response_wholejpeg.dart';
import 'simple_frame_app.dart';
import 'toggle.dart';

void main() => runApp(const MainApp());

final _log = Logger("MainApp");

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  MainAppState createState() => MainAppState();
}

class MainAppState extends State<MainApp> with SimpleFrameAppState {
  // Phone to Frame flags
  static const streamFlag = 0x0a;

  // stream subscription to pull application data back from camera
  StreamSubscription<Uint8List>? _imageDataResponseStream;

  // camera settings
  int _qualityIndex = 2;
  final List<double> _qualityValues = [10, 25, 50, 100];
  double _exposure = 0.0; // -2.0 <= val <= 2.0
  int _meteringModeIndex = 0;
  final List<String> _meteringModeValues = ['SPOT', 'CENTER_WEIGHTED', 'AVERAGE'];
  final int _autoExpGainTimes = 0; // val >= 0; number of times auto exposure and gain algorithm will be run every 100ms
  double _shutterKp = 0.1;  // val >= 0 (we offer 0.1 .. 0.5)
  int _shutterLimit = 6000; // 4 < val < 16383
  double _gainKp = 1.0;     // val >= 0 (we offer 1.0 .. 5.0)
  int _gainLimit = 248;     // 0 <= val <= 248
  bool _cameraSettingsChanged = true;

  // details for the live camera feed
  Image? _currentImage;
  final Stopwatch _stopwatch = Stopwatch();
  int _imageSize = 0;
  int _elapsedMs = 0;

  MainAppState() {
    Logger.root.level = Level.INFO;
    Logger.root.onRecord.listen((record) {
      debugPrint('${record.level.name}: ${record.time}: ${record.message}');
    });
  }

  /// Request a stream of photos from the Frame and receive the data back, update an image to animate
  @override
  Future<void> run() async {
    currentState = ApplicationState.running;
    if (mounted) setState(() {});

    try {
      // set up the data response handler for the photos
      _imageDataResponseStream?.cancel();
      _imageDataResponseStream = imageDataResponseWholeJpeg(frame!.dataResponse).listen((imageData) {
        // received a whole-image Uint8List with jpeg header and footer included
        _stopwatch.stop();

        try {
          Image im = Image.memory(imageData, gaplessPlayback: true);

          _elapsedMs = _stopwatch.elapsedMilliseconds;
          _imageSize = imageData.length;
          _log.fine('Image file size in bytes: $_imageSize, elapsedMs: $_elapsedMs');
          _currentImage = im;
          if (mounted) setState(() {});

          // start the timer for the next image coming in
          _stopwatch.reset();
          _stopwatch.start();

        } catch (e) {
          _log.severe('Error converting bytes to image: $e');

          currentState = ApplicationState.ready;
          if (mounted) setState(() {});
        }
      });

      // start the timer for the first image coming
      _stopwatch.reset();
      _stopwatch.start();

      // kick off the photo streaming
      await frame!.sendDataRaw(ToggleMsg.pack(streamFlag, true));

      // Main loop on our side
      while (currentState == ApplicationState.running) {
        // check for updated camera settings and send to Frame
        if (_cameraSettingsChanged) {
          _cameraSettingsChanged = false;
          await frame!.sendDataRaw(CameraSettingsMsg.pack(_qualityIndex, _autoExpGainTimes, _meteringModeIndex, _exposure, _shutterKp, _shutterLimit, _gainKp, _gainLimit));
        }

        // yield so we're not running hot on the UI thread
        await Future.delayed(const Duration(milliseconds: 250));
      }

      // tell the frame to stop taking photos and sending
      await frame!.sendDataRaw(ToggleMsg.pack(streamFlag, false));
      _imageDataResponseStream!.cancel();

    } catch (e) {
      _log.fine('Error executing application logic: $e');
    }

    currentState = ApplicationState.ready;
    if (mounted) setState(() {});
  }

  @override
  Future<void> cancel() async {
    currentState = ApplicationState.stopping;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Frame Live Camera Feed',
      theme: ThemeData.dark(),
      home: Scaffold(
        appBar: AppBar(
          title: const Text("Frame Live Camera Feed"),
          actions: [getBatteryWidget()]
        ),
        drawer: Drawer(
          child: ListView(
            padding: EdgeInsets.zero,
            children: <Widget>[
              const DrawerHeader(
                decoration: BoxDecoration(
                  color: Colors.blue,
                ),
                child: Text('Camera Settings',
                  style: TextStyle(color: Colors.white, fontSize: 24),
                  ),
              ),
              ListTile(
                title: const Text('Quality'),
                subtitle: Slider(
                  value: _qualityIndex.toDouble(),
                  min: 0,
                  max: _qualityValues.length - 1,
                  divisions: _qualityValues.length - 1,
                  label: _qualityValues[_qualityIndex].toString(),
                  onChanged: (value) {
                    setState(() {
                      _qualityIndex = value.toInt();
                    });
                  },
                  onChangeEnd: (value) {
                      _cameraSettingsChanged = true;
                  },
                ),
              ),
              ListTile(
                title: const Text('Auto Exposure/Gain Runs'),
                subtitle: Slider(
                  value: _autoExpGainTimes.toDouble(),
                  min: 0,
                  max: 10,
                  divisions: 10,
                  label: _autoExpGainTimes.toInt().toString(),
                  // live camera feed does exposure runs every 100ms
                  // until the prior image is completely sent
                  onChanged: null,
                  onChangeEnd: (value) {
                      _cameraSettingsChanged = true;
                  },
                ),
              ),
              ListTile(
                title: const Text('Metering Mode'),
                subtitle: DropdownButton<int>(
                  value: _meteringModeIndex,
                  onChanged: (int? newValue) {
                    setState(() {
                      _meteringModeIndex = newValue!;
                      _cameraSettingsChanged = true;
                    });
                  },
                  items: _meteringModeValues
                      .map<DropdownMenuItem<int>>((String value) {
                    return DropdownMenuItem<int>(
                      value: _meteringModeValues.indexOf(value),
                      child: Text(value),
                    );
                  }).toList(),
                ),
              ),
              ListTile(
                title: const Text('Exposure'),
                subtitle: Slider(
                  value: _exposure,
                  min: -2,
                  max: 2,
                  divisions: 8,
                  label: _exposure.toString(),
                  onChanged: (value) {
                    setState(() {
                      _exposure = value;
                    });
                  },
                  onChangeEnd: (value) {
                      _cameraSettingsChanged = true;
                  },
                ),
              ),
              ListTile(
                title: const Text('Shutter KP'),
                subtitle: Slider(
                  value: _shutterKp,
                  min: 0.1,
                  max: 0.5,
                  divisions: 4,
                  label: _shutterKp.toStringAsFixed(1),
                  onChanged: (value) {
                    setState(() {
                      _shutterKp = value;
                    });
                  },
                  onChangeEnd: (value) {
                      _cameraSettingsChanged = true;
                  },
                ),
              ),
              ListTile(
                title: const Text('Shutter Limit'),
                subtitle: Slider(
                  value: _shutterLimit.toDouble(),
                  min: 4,
                  max: 16383,
                  divisions: 10,
                  label: _shutterLimit.toStringAsFixed(0),
                  onChanged: (value) {
                    setState(() {
                      _shutterLimit = value.toInt();
                    });
                  },
                  onChangeEnd: (value) {
                      _cameraSettingsChanged = true;
                  },
                ),
              ),
              ListTile(
                title: const Text('Gain KP'),
                subtitle: Slider(
                  value: _gainKp,
                  min: 1.0,
                  max: 5.0,
                  divisions: 4,
                  label: _gainKp.toStringAsFixed(1),
                  onChanged: (value) {
                    setState(() {
                      _gainKp = value;
                    });
                  },
                  onChangeEnd: (value) {
                      _cameraSettingsChanged = true;
                  },
                ),
              ),
              ListTile(
                title: const Text('Gain Limit'),
                subtitle: Slider(
                  value: _gainLimit.toDouble(),
                  min: 0,
                  max: 248,
                  divisions: 8,
                  label: _gainLimit.toStringAsFixed(0),
                  onChanged: (value) {
                    setState(() {
                      _gainLimit = value.toInt();
                    });
                  },
                  onChangeEnd: (value) {
                      _cameraSettingsChanged = true;
                  },
                ),
              ),
            ],
          ),
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Transform(
                alignment: Alignment.center,
                // images are rotated 90 degrees clockwise from the Frame
                // so reverse that for display
                transform: Matrix4.rotationZ(-pi*0.5),
                child: _currentImage,
              )
            ),
            const Divider(),
            if (_currentImage != null)  Text('Size: ${_imageSize>>10} kb, Elapsed: $_elapsedMs ms'),
          ],
        ),
        floatingActionButton: getFloatingActionButtonWidget(const Icon(Icons.video_camera_back), const Icon(Icons.cancel)),
        persistentFooterButtons: getFooterButtonsWidget(),
      ),
    );
  }
}
