import 'dart:async';

import 'package:agora_rtc_engine/rtc_engine.dart';
import 'package:flutter/foundation.dart';
import 'package:network_communication/src/messaging/notification_exception.dart';
import 'package:network_communication/src/messaging/notification_handler.dart';
import 'package:permission_handler/permission_handler.dart';

import '../config.dart';
import 'voip_exception.dart';
import 'voip_provider.dart';

class AgoraRtcEnginAdapter with ChangeNotifier implements VoIPProvider {
  RtcEngine _rtcEngine;
  final RtcEngineEventHandler _eventHandler;
  final PermissionHandler _permissionHandler;
  final NotificationHandler _notificationHandler;

  Timer _callResponseTimeoutTimer;
  StreamSubscription _lastCallRejectionSubscription;
  final _incomingCallStreamController = StreamController<String>.broadcast();
  final _connectionStateStreamController =
      StreamController<VoIPConnectionState>.broadcast();

  AgoraRtcEnginAdapter({
    RtcEngine realTimeCommunicationEngine,
    RtcEngineEventHandler eventHandler,
    PermissionHandler permissionHandler,
    @required NotificationHandler notificationHandler,
  })  : _rtcEngine = realTimeCommunicationEngine,
        _eventHandler = eventHandler ?? RtcEngineEventHandler(),
        _permissionHandler = permissionHandler ?? PermissionHandler(),
        _notificationHandler = notificationHandler;

  @override
  Stream<String> get incomingCallStream => _incomingCallStreamController.stream;
  @override
  Stream<VoIPConnectionState> get connectionStateStream =>
      _connectionStateStreamController.stream;

  @override
  Future<void> initialize() async {
    final microphonePesmisionStatus =
        await _permissionHandler.requestMicrophonePermission();
    if (microphonePesmisionStatus.isGranted) {
      await _initializeRtcEngine();
      _setUpIncomingCallStream();
    } else if (microphonePesmisionStatus.isDenied) {
      throw VoIPException.microphonePermissionDenied();
    } else if (microphonePesmisionStatus.isPermanentlyDenied) {
      throw VoIPException.microphonePermissionPermanentlyDenied();
    } else {
      throw VoIPException.microphonePermissionRestricted();
    }
  }

  Future<void> _initializeRtcEngine() async {
    _rtcEngine ??= await RtcEngine.create(agoraAppId);
    await _rtcEngine.setChannelProfile(ChannelProfile.Communication);
    await _rtcEngine.enableAudio();
    _rtcEngine.setEventHandler(_eventHandler);
    _handleConnectionStateChanges();
  }

  void _handleConnectionStateChanges() {
    _eventHandler.connectionStateChanged = (state, _) {
      switch (state) {
        case ConnectionStateType.Connected:
          _connectionStateStreamController.add(VoIPConnectionState.connected);
          break;
        case ConnectionStateType.Connecting:
          _connectionStateStreamController.add(VoIPConnectionState.connecting);
          break;
        case ConnectionStateType.Disconnected:
          _connectionStateStreamController
              .add(VoIPConnectionState.disconnected);
          break;
        case ConnectionStateType.Reconnecting:
          _connectionStateStreamController
              .add(VoIPConnectionState.reconnecting);
          break;
        default:
          break;
      }
    };
  }

  void _setUpIncomingCallStream() {
    _notificationHandler.silentNotificationStream.listen((notification) {
      if (notification['reason'] == SilentNotificationReason.incomingCall) {
        _incomingCallStreamController.add(notification['senderId'].toString());
      }
    });
  }

  @override
  Future<void> destroy() async {
    await _rtcEngine?.destroy();
    await _connectionStateStreamController.close();
    await _incomingCallStreamController.close();
    _callResponseTimeoutTimer?.cancel();
  }

  @override
  Future<void> leaveCall() async {
    await _rtcEngine.leaveChannel();
  }

  @override
  Future<void> makeCall({
    @required String callId,
    @required String recipientId,
    @required VoidCallback onCallAccepted,
    @required void Function(CallLeaveReason) onCallLeft,
    @required VoidCallback onCallRejected,
    @required void Function(CallFailureReason) onCallFailed,
    VoidCallback onCallSuccess,
    Duration responseTimeout = const Duration(seconds: 30),
  }) async {
    _handleCallEvents(onCallAccepted, onCallLeft, onCallRejected, onCallFailed,
        onCallSuccess);
    try {
      await _notificationHandler.sendIncomingCallNotification(recipientId);
    } on NotificationException catch (e) {
      if (e.exceptionType == NotificationExceptionType.unknownRecipientId) {
        onCallFailed(CallFailureReason.unregisteredRecipientId);
      } else {
        onCallFailed(CallFailureReason.unknwon);
      }
      return null;
    }
    await _rtcEngine.joinChannel(null, callId, null, 0);
    _callResponseTimeoutTimer = Timer(responseTimeout, () {
      onCallFailed(CallFailureReason.timedOut);
      _rtcEngine.leaveChannel();
    });
  }

  void _handleCallEvents(
    VoidCallback onCallAccepted,
    void Function(CallLeaveReason) onCallLeft,
    VoidCallback onCallRejected,
    void Function(CallFailureReason) onCallFailed,
    VoidCallback onCallSuccess,
  ) {
    _eventHandler.userJoined = (_, __) {
      _callResponseTimeoutTimer.cancel();
      onCallAccepted();
      _lastCallRejectionSubscription.cancel();
    };
    _eventHandler.joinChannelSuccess = (_, __, ___) => onCallSuccess();
    _handleCallLeftEvent(onCallLeft);
    _handleCallRejectedEvent(onCallRejected);
    _eventHandler.error = (errorCode) {
      if (errorCode == ErrorCode.InvalidChannelId) {
        onCallFailed(CallFailureReason.invalidCallId);
      }
    };
  }

  void _handleCallRejectedEvent(VoidCallback onCallRejected) {
    _lastCallRejectionSubscription = _notificationHandler
        .silentNotificationStream
        .listen((notificationData) {
      if (notificationData['reason'] == SilentNotificationReason.callRejected) {
        onCallRejected();
        _rtcEngine.leaveChannel();
        _lastCallRejectionSubscription.cancel();
      }
    });
  }

  @override
  Future<void> acceptCall({
    @required String callId,
    @required void Function(CallLeaveReason) onCallLeft,
    @required VoidCallback onCallAccepted,
    @required void Function(CallFailureReason) onFail,
  }) async {
    _eventHandler.error = (errorCode) {
      if (errorCode == ErrorCode.InvalidChannelId) {
        onFail(CallFailureReason.invalidCallId);
      }
    };
    _eventHandler.joinChannelSuccess = (_, __, ___) => onCallAccepted();
    _handleCallLeftEvent(onCallLeft);
    await _rtcEngine.joinChannel(null, callId, null, 0);
  }

  void _handleCallLeftEvent(
    void Function(CallLeaveReason) onCallLeft,
  ) {
    _eventHandler.userOffline = (_, reason) {
      if (reason == UserOfflineReason.Quit) {
        onCallLeft(CallLeaveReason.hangUp);
        _rtcEngine.leaveChannel();
      } else {
        onCallLeft(CallLeaveReason.offline);
        _rtcEngine
            .leaveChannel(); // TODO if the user will be dropped offline the wifi is desabled on the device after 20s .
      }
    };
  }

  @override
  Future<void> rejectCall(String callId) async {
    await _notificationHandler.sendSilentNotification(
      data: {'reason': SilentNotificationReason.callRejected},
      recipientId: callId,
    );
  }
}

class PermissionHandler {
  Future<PermissionStatus> requestMicrophonePermission() =>
      Permission.microphone.request();
}
