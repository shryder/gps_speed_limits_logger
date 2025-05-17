import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_speed_dial/flutter_speed_dial.dart';
import 'package:geolocator/geolocator.dart';
import 'package:timeago_flutter/timeago_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';
import 'package:http/http.dart' as http;

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GPS Speed Limits Logger',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const MyHomePage(title: 'Speed Limits Logger'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class LogEntry {
  final Position gpsLocation;
  final List<Position> previousGpsLocations;
  final int speedLimit;
  final int timestamp;
  final String uuid;

  const LogEntry(this.gpsLocation, this.previousGpsLocations, this.speedLimit, this.timestamp, this.uuid);

  Map<String, dynamic> toJson() => {
    'gpsLocation': gpsLocation,
    'previousLocations': previousGpsLocations,
    'speedLimit': speedLimit,
    'timestamp':  timestamp,
    'uuid':       uuid,
  };
}

class _MyHomePageState extends State<MyHomePage> {
  Position? _currentPosition;
  final _previousPositions = <Position>[];
  final _logEntries = <LogEntry>[];
  LocationPermission _locationPermission = LocationPermission.denied;
  bool _gpsEnabled = false;
  bool _submittingEntries = false;
  final _scrollController = ScrollController();

  void _subscribeToLocationStream() {
    var locationSettings = AndroidSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 0,
      forceLocationManager: true,
      intervalDuration: const Duration(seconds: 1),
    );

    StreamSubscription<Position> positionStream = Geolocator.getPositionStream(locationSettings: locationSettings).listen((Position? position) {
      if (position == null) {
        return;
      }

      print('longt ${position.latitude.toString()}, lat ${position.longitude.toString()}');

      _setLocation(position);

      // Keep history of previous locations as long as they are 5 seconds apart from each other
      final now = DateTime.now();
      DateTime lastSaved = DateTime.fromMillisecondsSinceEpoch(0);
      if (_previousPositions.isNotEmpty) {
        lastSaved = _previousPositions[_previousPositions.length - 1].timestamp;
      }

      if (now.difference(lastSaved).inSeconds >= 5) {
        lastSaved = now;

        _previousPositions.add(position);

        if (_previousPositions.length > 3) {
          _previousPositions.removeAt(0);
        }
      }
    });
  }


  void _checkGPSEnabled() async {
    var isGpsEnabled = await Geolocator.isLocationServiceEnabled();

    setState(() {
      _gpsEnabled = isGpsEnabled;
    });
  }

  Future<void> _checkLocationPermission() async {
    var checkPerms = await Geolocator.checkPermission();
    if (checkPerms == LocationPermission.denied) {
      checkPerms = await Geolocator.requestPermission();
      if (checkPerms == LocationPermission.denied) {
        // Permissions are denied, next time you could try
        // requesting permissions again (this is also where
        // Android's shouldShowRequestPermissionRationale
        // returned true. According to Android guidelines
        // your App should show an explanatory UI now.
        return Future.error('Location permissions are denied');
      }
    }

    setState(() {
      _locationPermission = checkPerms;
    });
  }

  @override
  void initState() {
    super.initState();

    _checkLocationPermission().then((_) => _checkGPSEnabled()).then((_) => _subscribeToLocationStream());
  }


  String _buildPermissionText() {
    switch (_locationPermission) {
      case LocationPermission.whileInUse:
        return 'Location permission: Allow Only While In Use.';
      case LocationPermission.always:
        return 'Location permission: Allow Always.';
      case LocationPermission.denied:
        return 'Location permission: Denied';
      case LocationPermission.deniedForever:
        return 'Location permission: Permanently Denied (Please enable from settings)';
      case LocationPermission.unableToDetermine:
        return "Location permission: ERROR Unable to determine";
    }
  }

  void _setLocation(Position position) {
    setState(() {
      _currentPosition = position;
    });
  }

  void _logSpeedLimit(speed) {
    if (_currentPosition == null) {
      return;
    }


    setState(() {
      _logEntries.add(LogEntry(_currentPosition!, _previousPositions, speed, DateTime.now().millisecondsSinceEpoch, Uuid().v4()));
    });


    WidgetsBinding.instance.addPostFrameCallback((_) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToBottom();
      });
    });
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;

    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  Future<Map<String, dynamic>> _submitLogEntriesToServer() async {
    final uri = Uri.parse("http://localhost:3000/api/submit");

    final response = await http.post(
      uri,
      headers: {
        'Content-Type': 'application/json',
      },
      body: jsonEncode(_logEntries),
    ).timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        throw Exception('Error! Request timed out after 5 seconds');
      },
    );

    if (response.statusCode >= 200 && response.statusCode < 300) {
      var responseJson = jsonDecode(response.body) as Map<String, dynamic>;

      if (responseJson.containsKey("success") && responseJson["success"] == true) {
        return responseJson;
      } else {
        throw Exception("Error! Couldn't submit speed limit to server: ${response.body}");
      }
    } else {
      throw Exception('Failed to POST data (status: ${response.statusCode}): ${response.body}');
    }
  }

  Future<void> _openInMaps(double? lat, double? lng) async {
    if (lat == null || lng == null) return;

    final uri = Uri.parse('https://www.google.com/maps/search/?api=1&query=$lat,$lng');

    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      throw Exception('Could not open Google Maps');
    }
  }

  String _buildClipboardData() {
    return jsonEncode(_logEntries);
  }

  @override
  Widget build(BuildContext context) {
    const presetLimits = [ 40, 60, 80, 100, 120 ];
    var lat = "";
    var lng = "";
    if (_currentPosition != null) {
      lat = _currentPosition?.latitude.toStringAsFixed(6) ?? '—';
      lng = _currentPosition?.longitude.toStringAsFixed(6) ?? '—';
    }

    Position? lastSavedPosition;
    if (_previousPositions.isNotEmpty) {
      lastSavedPosition = _previousPositions[_previousPositions.length - 1];
    }

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            _gpsEnabled ? Text("GPS is Enabled.") : Text("GPS is NOT enabled!", style: TextStyle(color: Colors.red)),
            Text(_buildPermissionText(), textAlign: TextAlign.center,),
            Text("Longtitude: ${lng} Latitude $lat", textAlign: TextAlign.center,),
            lastSavedPosition != null ? Timeago(
                date: lastSavedPosition.timestamp,
                refreshRate: const Duration(seconds: 1),
                builder: (context, value) {
                  if (lastSavedPosition!.timestamp.difference(DateTime.now()).inSeconds > 10) {
                    return Text("WARNING! Last location update was too long ago: $value");
                  }

                  return Text("GPS Position is up to date.");
                }
            ) : Text(
                "No last position. This message should disappear in a few seconds.",
                style: TextStyle(color: Colors.red),
                textAlign: TextAlign.center
            ),

            GestureDetector(
                onTap: () async {
                  try {
                    await _openInMaps(_currentPosition?.latitude, _currentPosition?.longitude);
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(e.toString())),
                      );
                    }
                  }
                },
                child: Text(
                  "Open Google Maps at current location",
                  style: TextStyle(
                    color: Colors.blue,
                    decoration: TextDecoration.underline,
                  ),
                )
            ),

            SizedBox( height: 24 ),

            Wrap(
              spacing: 12,
              runSpacing: 12,
              alignment: WrapAlignment.center,

              children: presetLimits.map((limit) {
                return SpeedLimitButton(speed: limit, onPressed: () {
                  _logSpeedLimit(limit);
                });
              }).toList(),
            ),

            SizedBox( height: 24 ),

            SizedBox(
              height: 200, // whatever height you want
              child: ListView.builder(
                controller: _scrollController,
                itemCount: _logEntries.length,
                itemBuilder: (context, index) {
                  var logEntry = _logEntries[index];

                  var speedLimit = logEntry.speedLimit;
                  var long = logEntry.gpsLocation.longitude;
                  var lat = logEntry.gpsLocation.latitude;

                  return Dismissible(
                      key: ValueKey(logEntry),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        color: Colors.red,
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: const Icon(Icons.delete, color: Colors.white),
                      ),
                      onDismissed: (dir) {
                        setState(() {
                          _logEntries.removeAt(index);
                        });

                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Entry deleted')),
                        );
                      },
                      child: Timeago(
                          date: DateTime.fromMillisecondsSinceEpoch(logEntry.timestamp),
                          refreshRate: const Duration(seconds: 1),
                          builder: (context, value) {
                            return ListTile(
                              onTap: () async {
                                try {
                                  await _openInMaps(lat, long);
                                } catch (e) {
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text(e.toString())),
                                    );
                                  }
                                }
                              },
                              title: Text.rich(
                                TextSpan(
                                  text: "[$value] Reported $speedLimit kmph speed limit at ",
                                  children: [
                                    TextSpan(
                                        text: "${long.toStringAsFixed(6)} ; ${lat.toStringAsFixed(6)}",
                                      style: TextStyle(
                                        color: Colors.blue,
                                        decoration: TextDecoration.underline,
                                      )
                                    )
                                  ]
                                )
                              )
                            );
                          }
                      )
                  );
                },
              ),
            )
          ],
        ),
      ),
      floatingActionButton: SpeedDial(
          tooltip: "Submit Logs to Server",
          icon: Icons.add,
          children: [
            SpeedDialChild(
              onTap: () async {
                if (_submittingEntries) return;

                _submittingEntries = true;

                showDialog(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => const Center(
                    child: CircularProgressIndicator(),
                  ),
                );

                try {
                  await _submitLogEntriesToServer();

                  if (context.mounted) {
                    // Successfully submitted speed limits to the server
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text("Successfully submitted speed limits to the server", style: TextStyle(color: Colors.black)), backgroundColor: Colors.greenAccent),
                    );
                  }
                } catch (e) {
                  if (context.mounted) {
                    // Could be success message too lol
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(e.toString(), style: TextStyle(color: Colors.white)), backgroundColor: Colors.redAccent),
                    );
                  }
                }

                if (context.mounted) {
                  Navigator.of(context, rootNavigator: true).pop();
                }

                _submittingEntries = false;
              },
              child: const Icon(Icons.upload),
              label: "Upload to server"
            ),
            SpeedDialChild(
              onTap: () {
                Clipboard.setData(ClipboardData(text: _buildClipboardData()));
              },
              child: const Icon(Icons.copy),
              label: "Copy to clipboard"
            )
          ]
      ),
    );
  }
}

class SpeedLimitButton extends StatelessWidget {
  final int speed;
  final double size;
  final VoidCallback onPressed;

  const SpeedLimitButton({
    super.key,
    required this.speed,
    required this.onPressed,
    this.size = 80.0,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(size / 2),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white,
            border: Border.all(color: Colors.red, width: 4),
          ),
          alignment: Alignment.center,
          child: Text(
            '$speed',
            style: TextStyle(
              fontSize: size * 0.4,
              fontWeight: FontWeight.bold,
              color: Colors.black,
            ),
          ),
        ),
      ),
    );
  }
}