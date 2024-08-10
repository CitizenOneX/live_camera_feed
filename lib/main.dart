import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'simple_frame_app.dart';

void main() => runApp(const MainApp());

final _log = Logger("MainApp");

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  MainAppState createState() => MainAppState();
}

class MainAppState extends State<MainApp> with SimpleFrameAppState {
  // Phone to Frame flags
  static const startStreamFlag = 0x0a;
  static const stopStreamFlag = 0x0b;
  static const cameraSettingsFlag = 0x0d;

  // stream subscription to pull application data back from camera
  StreamSubscription<List<int>>? _dataResponseStream;

  // camera settings
  int _qualityIndex = 2;
  final List<double> _qualityValues = [10, 25, 50, 100];
  double _exposure = 0.0; // -2.0 <= val <= 2.0
  int _meteringModeIndex = 0;
  final List<String> _meteringModeValues = ['SPOT', 'CENTER_WEIGHTED', 'AVERAGE'];
  int _autoExpGainTimes = 0; // val >= 0; number of times auto exposure and gain algorithm will be run every 100ms
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
  Future<void> runApplication() async {
    currentState = ApplicationState.running;
    if (mounted) setState(() {});

    try {
      _dataResponseStream?.cancel();

      // try to get the Frame into a known state by making sure there's no main loop running
      frame!.sendBreakSignal();
      await Future.delayed(const Duration(milliseconds: 500));

      // clean up by deregistering any handler and deleting any prior script
      await frame!.sendString('frame.bluetooth.receive_callback(nil);print(0)', awaitResponse: true);
      await Future.delayed(const Duration(milliseconds: 500));
      await frame!.sendString('frame.file.remove("frame_app.lua");print(0)', awaitResponse: true);
      await Future.delayed(const Duration(milliseconds: 500));

      // send our frame_app to the Frame
      // It sends image data from the camera as fast as it can over bluetooth
      await frame!.uploadScript('frame_app.lua', 'assets/frame_app.lua');
      await Future.delayed(const Duration(milliseconds: 500));

      // kick off the main application loop
      await frame!.sendString('require("frame_app")', awaitResponse: true);

      // -----------------------------------------------------------------------
      // frame_app is installed on Frame and running, start our application loop
      // -----------------------------------------------------------------------

      // the image data as a list of bytes that accumulates with each packet
      List<int> imageData = List.empty(growable: true);

      // set up the data response handler for the photos
      _dataResponseStream = frame!.dataResponse.listen((data) {
        // non-final chunks have a first byte of 7
        if (data[0] == 7) {
          imageData += data.sublist(1);
        }
        // the last chunk has a first byte of 8 so stop after this
        else if (data[0] == 8) {
          _stopwatch.stop();
          imageData += data.sublist(1);

          try {
            Image im = Image.memory(Uint8List.fromList(imageData), gaplessPlayback: true);

            _elapsedMs = _stopwatch.elapsedMilliseconds;
            _imageSize = imageData.length;
            imageData.clear();
            _log.info('Image file size in bytes: $_imageSize, elapsedMs: $_elapsedMs');
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
        }
        else if (data[0] == 0x0c) {
          // ignore the battery level updates, they're handled by SimpleFrameApp already
        }
        else {
          _log.severe('Unexpected initial byte: ${data[0]}');
        }
      });

      // start the timer for the first image coming
      _stopwatch.reset();
      _stopwatch.start();

      // kick off the photo streaming
      await frame!.sendData([startStreamFlag]);

      // Main loop on our side
      while (currentState == ApplicationState.running) {
        // check for updated camera settings and send to Frame
        if (_cameraSettingsChanged) {
          _cameraSettingsChanged = false;
          await frame!.sendData(makeSettingsPayload());
        }

        // yield so we're not running hot on the UI thread
        await Future.delayed(const Duration(milliseconds: 500));
      }

      // ----------------------------------------------------------------------
      // finished the main application loop, shut it down here and on the Frame
      // ----------------------------------------------------------------------
      // tell the frame to stop taking photos and sending
      await frame!.sendData([stopStreamFlag]);
      _dataResponseStream!.cancel();

      // send a break to stop the Lua app loop on Frame
      await frame!.sendBreakSignal();
      await Future.delayed(const Duration(milliseconds: 500));

      // deregister the data handler
      await frame!.sendString('frame.bluetooth.receive_callback(nil);print(0)', awaitResponse: true);
      await Future.delayed(const Duration(milliseconds: 500));

    } catch (e) {
      _log.fine('Error executing application logic: $e');
    }

    currentState = ApplicationState.ready;
    if (mounted) setState(() {});
  }

  @override
  Future<void> interruptApplication() async {
    currentState = ApplicationState.stopping;
    if (mounted) setState(() {});
  }

  /// Corresponding parser in frame_app.lua data_handler()
  List<int> makeSettingsPayload() {
    // exposure is a double in the range -2.0 to 2.0, so map that to an unsigned byte 0..255
    // by multiplying by 64, adding 128 and truncating
    int intExp;
    if (_exposure >= 2.0) {
      intExp = 255;
    }
    else if (_exposure <= -2.0) {
      intExp = 0;
    }
    else {
      intExp = ((_exposure * 64) + 128).floor();
    }

    int intShutKp = (_shutterKp * 10).toInt();
    int intShutLimMsb = _shutterLimit >> 8;
    int intShutLimLsb = _shutterLimit & 0xFF;
    int intGainKp = (_gainKp * 10).toInt();

    return [cameraSettingsFlag, _qualityIndex, _autoExpGainTimes, _meteringModeIndex,
            intExp, intShutKp, intShutLimMsb, intShutLimLsb, intGainKp, _gainLimit];
  }

  @override
  Widget build(BuildContext context) {
    // work out the states of the footer buttons based on the app state
    List<Widget> pfb = [];

    switch (currentState) {
      case ApplicationState.disconnected:
        pfb.add(TextButton(onPressed: scanOrReconnectFrame, child: const Text('Connect Frame')));
        pfb.add(const TextButton(onPressed: null, child: Text('Live Feed')));
        pfb.add(const TextButton(onPressed: null, child: Text('Finish')));
        break;

      case ApplicationState.initializing:
      case ApplicationState.scanning:
      case ApplicationState.connecting:
      case ApplicationState.stopping:
      case ApplicationState.disconnecting:
        pfb.add(const TextButton(onPressed: null, child: Text('Connect Frame')));
        pfb.add(const TextButton(onPressed: null, child: Text('Live Feed')));
        pfb.add(const TextButton(onPressed: null, child: Text('Finish')));
        break;

      case ApplicationState.ready:
        pfb.add(const TextButton(onPressed: null, child: Text('Connect Frame')));
        pfb.add(TextButton(onPressed: runApplication, child: const Text('Live Feed')));
        pfb.add(TextButton(onPressed: disconnectFrame, child: const Text('Finish')));
        break;

      case ApplicationState.running:
        pfb.add(const TextButton(onPressed: null, child: Text('Connect Frame')));
        pfb.add(TextButton(onPressed: interruptApplication, child: const Text('Stop Feed')));
        pfb.add(const TextButton(onPressed: null, child: Text('Finish')));
        break;
    }

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
                  onChanged: (double value) {
                    setState(() {
                      _qualityIndex = value.toInt();
                      _cameraSettingsChanged = true;
                    });
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
                title: const Text('Auto Exposure/Gain Runs'),
                subtitle: Slider(
                  value: _autoExpGainTimes.toDouble(),
                  min: 0,
                  max: 10,
                  divisions: 10,
                  label: _autoExpGainTimes.toInt().toString(),
                  onChanged: (double value) {
                    setState(() {
                      _autoExpGainTimes = value.toInt();
                      _cameraSettingsChanged = true;
                    });
                  },
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
                  onChanged: (double value) {
                    setState(() {
                      _exposure = value;
                      _cameraSettingsChanged = true;
                    });
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
                  onChanged: (double value) {
                    setState(() {
                      _shutterKp = value;
                      _cameraSettingsChanged = true;
                    });
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
                  onChanged: (double value) {
                    setState(() {
                      _shutterLimit = value.toInt();
                      _cameraSettingsChanged = true;
                    });
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
                  onChanged: (double value) {
                    setState(() {
                      _gainKp = value;
                      _cameraSettingsChanged = true;
                    });
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
                  onChanged: (double value) {
                    setState(() {
                      _gainLimit = value.toInt();
                      _cameraSettingsChanged = true;
                    });
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
        persistentFooterButtons: pfb,
      ),
    );
  }
}
