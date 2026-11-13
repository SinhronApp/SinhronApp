import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_l10n_en.dart';
import 'app_l10n_ru.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppL10n
/// returned by `AppL10n.of(context)`.
///
/// Applications need to include `AppL10n.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'gen/app_l10n.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppL10n.localizationsDelegates,
///   supportedLocales: AppL10n.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppL10n.supportedLocales
/// property.
abstract class AppL10n {
  AppL10n(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppL10n of(BuildContext context) {
    return Localizations.of<AppL10n>(context, AppL10n)!;
  }

  static const LocalizationsDelegate<AppL10n> delegate = _AppL10nDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('ru'),
  ];

  /// Chat list large title
  ///
  /// In en, this message translates to:
  /// **'Chats'**
  String get chatsTitle;

  /// No description provided for @tabChats.
  ///
  /// In en, this message translates to:
  /// **'Chats'**
  String get tabChats;

  /// No description provided for @tabCalls.
  ///
  /// In en, this message translates to:
  /// **'Calls'**
  String get tabCalls;

  /// No description provided for @tabContacts.
  ///
  /// In en, this message translates to:
  /// **'Contacts'**
  String get tabContacts;

  /// No description provided for @tabSettings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get tabSettings;

  /// No description provided for @folderAll.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get folderAll;

  /// No description provided for @folderPersonal.
  ///
  /// In en, this message translates to:
  /// **'Personal'**
  String get folderPersonal;

  /// No description provided for @folderGroups.
  ///
  /// In en, this message translates to:
  /// **'Groups'**
  String get folderGroups;

  /// No description provided for @folderUnread.
  ///
  /// In en, this message translates to:
  /// **'Unread'**
  String get folderUnread;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @mute.
  ///
  /// In en, this message translates to:
  /// **'Mute'**
  String get mute;

  /// No description provided for @archive.
  ///
  /// In en, this message translates to:
  /// **'Archive'**
  String get archive;

  /// No description provided for @pin.
  ///
  /// In en, this message translates to:
  /// **'Pin'**
  String get pin;

  /// No description provided for @markUnread.
  ///
  /// In en, this message translates to:
  /// **'Mark as unread'**
  String get markUnread;

  /// No description provided for @editFolder.
  ///
  /// In en, this message translates to:
  /// **'Edit folder'**
  String get editFolder;

  /// No description provided for @moveLeft.
  ///
  /// In en, this message translates to:
  /// **'Move left'**
  String get moveLeft;

  /// No description provided for @moveRight.
  ///
  /// In en, this message translates to:
  /// **'Move right'**
  String get moveRight;

  /// No description provided for @markAllRead.
  ///
  /// In en, this message translates to:
  /// **'Mark all as read'**
  String get markAllRead;

  /// No description provided for @deleteFolder.
  ///
  /// In en, this message translates to:
  /// **'Delete folder'**
  String get deleteFolder;

  /// No description provided for @chatsLoadError.
  ///
  /// In en, this message translates to:
  /// **'Chats could not be loaded'**
  String get chatsLoadError;

  /// No description provided for @pullToRetry.
  ///
  /// In en, this message translates to:
  /// **'Pull down to try again.'**
  String get pullToRetry;

  /// No description provided for @noChatsYet.
  ///
  /// In en, this message translates to:
  /// **'No chats yet'**
  String get noChatsYet;

  /// No description provided for @noChatsHint.
  ///
  /// In en, this message translates to:
  /// **'Tap the pencil at the top to message someone.'**
  String get noChatsHint;

  /// No description provided for @noChatsHere.
  ///
  /// In en, this message translates to:
  /// **'No chats here'**
  String get noChatsHere;

  /// No description provided for @folderEmptyHint.
  ///
  /// In en, this message translates to:
  /// **'Chats matching “{name}” will show up here.'**
  String folderEmptyHint(String name);

  /// No description provided for @archivedChats.
  ///
  /// In en, this message translates to:
  /// **'Archived chats'**
  String get archivedChats;

  /// No description provided for @unmute.
  ///
  /// In en, this message translates to:
  /// **'Unmute'**
  String get unmute;

  /// No description provided for @unarchive.
  ///
  /// In en, this message translates to:
  /// **'Unarchive'**
  String get unarchive;

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @open.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get open;

  /// No description provided for @unpin.
  ///
  /// In en, this message translates to:
  /// **'Unpin'**
  String get unpin;

  /// No description provided for @moveUp.
  ///
  /// In en, this message translates to:
  /// **'Move up'**
  String get moveUp;

  /// No description provided for @moveDown.
  ///
  /// In en, this message translates to:
  /// **'Move down'**
  String get moveDown;

  /// No description provided for @markRead.
  ///
  /// In en, this message translates to:
  /// **'Mark as read'**
  String get markRead;

  /// No description provided for @deleteChat.
  ///
  /// In en, this message translates to:
  /// **'Delete chat'**
  String get deleteChat;

  /// No description provided for @deleteChatConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete the chat with {name}? Messages on this device are removed for good.'**
  String deleteChatConfirm(String name);

  /// No description provided for @noMessagesYet.
  ///
  /// In en, this message translates to:
  /// **'No messages yet'**
  String get noMessagesYet;

  /// No description provided for @deleteFolderConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete the folder “{name}”? Chats stay where they are.'**
  String deleteFolderConfirm(String name);

  /// No description provided for @newFolder.
  ///
  /// In en, this message translates to:
  /// **'New folder'**
  String get newFolder;

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @folderName.
  ///
  /// In en, this message translates to:
  /// **'Folder name'**
  String get folderName;

  /// No description provided for @include.
  ///
  /// In en, this message translates to:
  /// **'Include'**
  String get include;

  /// No description provided for @allPersonal.
  ///
  /// In en, this message translates to:
  /// **'All personal chats'**
  String get allPersonal;

  /// No description provided for @allGroups.
  ///
  /// In en, this message translates to:
  /// **'All groups'**
  String get allGroups;

  /// No description provided for @hide.
  ///
  /// In en, this message translates to:
  /// **'Hide'**
  String get hide;

  /// No description provided for @archivedNotInFolders.
  ///
  /// In en, this message translates to:
  /// **'Archived chats never show in folders.'**
  String get archivedNotInFolders;

  /// No description provided for @mutedChats.
  ///
  /// In en, this message translates to:
  /// **'Muted chats'**
  String get mutedChats;

  /// No description provided for @readChats.
  ///
  /// In en, this message translates to:
  /// **'Read chats'**
  String get readChats;

  /// No description provided for @chatsInFolderCount.
  ///
  /// In en, this message translates to:
  /// **'Chats · {n} in folder'**
  String chatsInFolderCount(int n);

  /// No description provided for @folderChatHint.
  ///
  /// In en, this message translates to:
  /// **'Tap a chat to always include it, tap again to always hide it.'**
  String get folderChatHint;

  /// No description provided for @included.
  ///
  /// In en, this message translates to:
  /// **'Included'**
  String get included;

  /// No description provided for @hidden.
  ///
  /// In en, this message translates to:
  /// **'Hidden'**
  String get hidden;

  /// No description provided for @byRule.
  ///
  /// In en, this message translates to:
  /// **'By rule'**
  String get byRule;

  /// No description provided for @noArchivedChats.
  ///
  /// In en, this message translates to:
  /// **'No archived chats'**
  String get noArchivedChats;

  /// No description provided for @archiveHint.
  ///
  /// In en, this message translates to:
  /// **'Swipe a chat left and tap Archive to tuck it away here.'**
  String get archiveHint;

  /// No description provided for @searchHint.
  ///
  /// In en, this message translates to:
  /// **'Search messages, chats, media…'**
  String get searchHint;

  /// No description provided for @searchRecent.
  ///
  /// In en, this message translates to:
  /// **'Recent'**
  String get searchRecent;

  /// No description provided for @searchRecentClear.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get searchRecentClear;

  /// No description provided for @searchRecentRemove.
  ///
  /// In en, this message translates to:
  /// **'Remove {name} from recent'**
  String searchRecentRemove(String name);

  /// No description provided for @searchEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'Search chats and messages'**
  String get searchEmptyTitle;

  /// No description provided for @searchPrivacy.
  ///
  /// In en, this message translates to:
  /// **'Search runs only on this device — your server never sees what you\'re looking for.'**
  String get searchPrivacy;

  /// No description provided for @messagesSection.
  ///
  /// In en, this message translates to:
  /// **'Messages'**
  String get messagesSection;

  /// No description provided for @groupWithTime.
  ///
  /// In en, this message translates to:
  /// **'Group · {time}'**
  String groupWithTime(String time);

  /// No description provided for @noResults.
  ///
  /// In en, this message translates to:
  /// **'No results for “{query}”'**
  String noResults(String query);

  /// No description provided for @noResultsHint.
  ///
  /// In en, this message translates to:
  /// **'Try a shorter word or a different spelling. Search only looks at messages stored on this device.'**
  String get noResultsHint;

  /// No description provided for @openLink.
  ///
  /// In en, this message translates to:
  /// **'Open link'**
  String get openLink;

  /// No description provided for @errLibrary.
  ///
  /// In en, this message translates to:
  /// **'Photo library unavailable'**
  String get errLibrary;

  /// No description provided for @messageDeleted.
  ///
  /// In en, this message translates to:
  /// **'This message was deleted'**
  String get messageDeleted;

  /// No description provided for @replyToYourself.
  ///
  /// In en, this message translates to:
  /// **'Reply to yourself'**
  String get replyToYourself;

  /// No description provided for @replyTo.
  ///
  /// In en, this message translates to:
  /// **'Reply to {name}'**
  String replyTo(String name);

  /// No description provided for @statusFailed.
  ///
  /// In en, this message translates to:
  /// **'Not sent'**
  String get statusFailed;

  /// No description provided for @messageNotSent.
  ///
  /// In en, this message translates to:
  /// **'Not sent · Tap to retry'**
  String get messageNotSent;

  /// No description provided for @retrySend.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retrySend;

  /// No description provided for @msgInfo.
  ///
  /// In en, this message translates to:
  /// **'Info'**
  String get msgInfo;

  /// No description provided for @msgInfoSent.
  ///
  /// In en, this message translates to:
  /// **'Sent'**
  String get msgInfoSent;

  /// No description provided for @msgInfoDelivered.
  ///
  /// In en, this message translates to:
  /// **'Delivered'**
  String get msgInfoDelivered;

  /// No description provided for @msgInfoRead.
  ///
  /// In en, this message translates to:
  /// **'Read'**
  String get msgInfoRead;

  /// No description provided for @msgInfoNotYet.
  ///
  /// In en, this message translates to:
  /// **'Not delivered yet'**
  String get msgInfoNotYet;

  /// No description provided for @statusSending.
  ///
  /// In en, this message translates to:
  /// **'Sending'**
  String get statusSending;

  /// No description provided for @statusSent.
  ///
  /// In en, this message translates to:
  /// **'Sent'**
  String get statusSent;

  /// No description provided for @statusDelivered.
  ///
  /// In en, this message translates to:
  /// **'Delivered'**
  String get statusDelivered;

  /// No description provided for @kindVoice.
  ///
  /// In en, this message translates to:
  /// **'Voice message'**
  String get kindVoice;

  /// No description provided for @timerMinutes.
  ///
  /// In en, this message translates to:
  /// **'{n, plural, =1{1 minute} other{{n} minutes}}'**
  String timerMinutes(int n);

  /// No description provided for @timerHours.
  ///
  /// In en, this message translates to:
  /// **'{n, plural, =1{1 hour} other{{n} hours}}'**
  String timerHours(int n);

  /// No description provided for @timerDays.
  ///
  /// In en, this message translates to:
  /// **'{n, plural, =1{1 day} other{{n} days}}'**
  String timerDays(int n);

  /// No description provided for @timerWeeks.
  ///
  /// In en, this message translates to:
  /// **'{n, plural, =1{1 week} other{{n} weeks}}'**
  String timerWeeks(int n);

  /// No description provided for @couldNotEdit.
  ///
  /// In en, this message translates to:
  /// **'Could not edit the message'**
  String get couldNotEdit;

  /// No description provided for @reply.
  ///
  /// In en, this message translates to:
  /// **'Reply'**
  String get reply;

  /// No description provided for @copy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get copy;

  /// No description provided for @forward.
  ///
  /// In en, this message translates to:
  /// **'Forward'**
  String get forward;

  /// ADR-055: the chat with yourself, synced to all your devices (Telegram's Saved Messages)
  ///
  /// In en, this message translates to:
  /// **'Saved Messages'**
  String get savedMessages;

  /// No description provided for @savedMessagesHint.
  ///
  /// In en, this message translates to:
  /// **'Notes, links and files — on all your devices'**
  String get savedMessagesHint;

  /// Message menu: copy this message to Saved Messages
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get saveToSaved;

  /// No description provided for @savedToSaved.
  ///
  /// In en, this message translates to:
  /// **'Saved to Saved Messages'**
  String get savedToSaved;

  /// No description provided for @savedMessagesFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn’t open Saved Messages — check the connection and try again'**
  String get savedMessagesFailed;

  /// No description provided for @edit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get edit;

  /// No description provided for @select.
  ///
  /// In en, this message translates to:
  /// **'Select'**
  String get select;

  /// Message menu: open the message text where any part of it can be selected and copied
  ///
  /// In en, this message translates to:
  /// **'Select text'**
  String get selectText;

  /// No description provided for @copyAll.
  ///
  /// In en, this message translates to:
  /// **'Copy all'**
  String get copyAll;

  /// No description provided for @selectTextClose.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get selectTextClose;

  /// No description provided for @deleteMessagesConfirm.
  ///
  /// In en, this message translates to:
  /// **'{n, plural, =1{Delete this message?} other{Delete {n} messages?}}'**
  String deleteMessagesConfirm(int n);

  /// No description provided for @deleteForEveryone.
  ///
  /// In en, this message translates to:
  /// **'Delete for everyone'**
  String get deleteForEveryone;

  /// No description provided for @deleteForMe.
  ///
  /// In en, this message translates to:
  /// **'Delete for me'**
  String get deleteForMe;

  /// No description provided for @call.
  ///
  /// In en, this message translates to:
  /// **'Call'**
  String get call;

  /// No description provided for @timerSheetTitle.
  ///
  /// In en, this message translates to:
  /// **'Disappearing messages — new messages in this chat delete themselves on both phones after:'**
  String get timerSheetTitle;

  /// No description provided for @timerOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get timerOff;

  /// No description provided for @errNotEncrypted.
  ///
  /// In en, this message translates to:
  /// **'This chat isn’t encrypted, so nothing can be sent from it'**
  String get errNotEncrypted;

  /// No description provided for @errTooLarge.
  ///
  /// In en, this message translates to:
  /// **'File is too large (max 95 MB)'**
  String get errTooLarge;

  /// No description provided for @errOffline.
  ///
  /// In en, this message translates to:
  /// **'Not connected to the server'**
  String get errOffline;

  /// No description provided for @errCouldNotSend.
  ///
  /// In en, this message translates to:
  /// **'Couldn’t send. Check the connection and try again.'**
  String get errCouldNotSend;

  /// No description provided for @errCamera.
  ///
  /// In en, this message translates to:
  /// **'Camera unavailable or access denied'**
  String get errCamera;

  /// No description provided for @errFiles.
  ///
  /// In en, this message translates to:
  /// **'Couldn’t open Files. Try again.'**
  String get errFiles;

  /// No description provided for @errMic.
  ///
  /// In en, this message translates to:
  /// **'Microphone access denied'**
  String get errMic;

  /// No description provided for @pinnedMessage.
  ///
  /// In en, this message translates to:
  /// **'Pinned message'**
  String get pinnedMessage;

  /// No description provided for @quoteFallback.
  ///
  /// In en, this message translates to:
  /// **'Reply'**
  String get quoteFallback;

  /// No description provided for @you.
  ///
  /// In en, this message translates to:
  /// **'You'**
  String get you;

  /// No description provided for @chatEmptyHint.
  ///
  /// In en, this message translates to:
  /// **'Say hi 👋 — only the two of you can read this chat.'**
  String get chatEmptyHint;

  /// No description provided for @errLoadMessages.
  ///
  /// In en, this message translates to:
  /// **'Couldn’t load the messages. Close the chat and open it again.'**
  String get errLoadMessages;

  /// No description provided for @typing.
  ///
  /// In en, this message translates to:
  /// **'typing…'**
  String get typing;

  /// No description provided for @safetyChanged.
  ///
  /// In en, this message translates to:
  /// **'check number changed'**
  String get safetyChanged;

  /// No description provided for @online.
  ///
  /// In en, this message translates to:
  /// **'online'**
  String get online;

  /// No description provided for @youDeleted.
  ///
  /// In en, this message translates to:
  /// **'You deleted this message'**
  String get youDeleted;

  /// No description provided for @edited.
  ///
  /// In en, this message translates to:
  /// **'edited'**
  String get edited;

  /// No description provided for @messagePlaceholder.
  ///
  /// In en, this message translates to:
  /// **'Message'**
  String get messagePlaceholder;

  /// No description provided for @camera.
  ///
  /// In en, this message translates to:
  /// **'Camera'**
  String get camera;

  /// No description provided for @photos.
  ///
  /// In en, this message translates to:
  /// **'Photos'**
  String get photos;

  /// No description provided for @video.
  ///
  /// In en, this message translates to:
  /// **'Video'**
  String get video;

  /// No description provided for @document.
  ///
  /// In en, this message translates to:
  /// **'Document'**
  String get document;

  /// No description provided for @slideToCancel.
  ///
  /// In en, this message translates to:
  /// **'‹ Slide to cancel   ↑ lock'**
  String get slideToCancel;

  /// No description provided for @unreadMessages.
  ///
  /// In en, this message translates to:
  /// **'Unread messages'**
  String get unreadMessages;

  /// No description provided for @editMessage.
  ///
  /// In en, this message translates to:
  /// **'Edit message'**
  String get editMessage;

  /// No description provided for @selectedCount.
  ///
  /// In en, this message translates to:
  /// **'{n} selected'**
  String selectedCount(int n);

  /// No description provided for @statusRead.
  ///
  /// In en, this message translates to:
  /// **'Read'**
  String get statusRead;

  /// No description provided for @editedA11y.
  ///
  /// In en, this message translates to:
  /// **', edited'**
  String get editedA11y;

  /// No description provided for @kindPhoto.
  ///
  /// In en, this message translates to:
  /// **'Photo'**
  String get kindPhoto;

  /// No description provided for @timerOffByMe.
  ///
  /// In en, this message translates to:
  /// **'You turned off disappearing messages'**
  String get timerOffByMe;

  /// No description provided for @timerOffByPeer.
  ///
  /// In en, this message translates to:
  /// **'Disappearing messages turned off'**
  String get timerOffByPeer;

  /// No description provided for @timerSetByMe.
  ///
  /// In en, this message translates to:
  /// **'You set messages to disappear after {time}'**
  String timerSetByMe(String time);

  /// No description provided for @timerSetByPeer.
  ///
  /// In en, this message translates to:
  /// **'Messages now disappear after {time}'**
  String timerSetByPeer(String time);

  /// No description provided for @timeNow.
  ///
  /// In en, this message translates to:
  /// **'now'**
  String get timeNow;

  /// No description provided for @yesterday.
  ///
  /// In en, this message translates to:
  /// **'Yesterday'**
  String get yesterday;

  /// No description provided for @today.
  ///
  /// In en, this message translates to:
  /// **'Today'**
  String get today;

  /// No description provided for @couldNotShare.
  ///
  /// In en, this message translates to:
  /// **'Could not share'**
  String get couldNotShare;

  /// No description provided for @showQr.
  ///
  /// In en, this message translates to:
  /// **'Show a QR code instead'**
  String get showQr;

  /// No description provided for @verifiedBody.
  ///
  /// In en, this message translates to:
  /// **'You checked that this is really {name}.'**
  String verifiedBody(String name);

  /// No description provided for @safetyChangedBody.
  ///
  /// In en, this message translates to:
  /// **'{name}’s check number changed — most likely a new phone. Check again.'**
  String safetyChangedBody(String name);

  /// No description provided for @notVerifiedBody.
  ///
  /// In en, this message translates to:
  /// **'Messages are encrypted either way. Checking makes sure nobody is secretly in between.'**
  String get notVerifiedBody;

  /// No description provided for @neverShown.
  ///
  /// In en, this message translates to:
  /// **'Never shown'**
  String get neverShown;

  /// No description provided for @perChat.
  ///
  /// In en, this message translates to:
  /// **'Per chat'**
  String get perChat;

  /// No description provided for @off.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get off;

  /// No description provided for @previewOut.
  ///
  /// In en, this message translates to:
  /// **'Great! We just got back from the mountains 🏔'**
  String get previewOut;

  /// No description provided for @forwardTo.
  ///
  /// In en, this message translates to:
  /// **'Forward to…'**
  String get forwardTo;

  /// No description provided for @noOtherChats.
  ///
  /// In en, this message translates to:
  /// **'No other chats'**
  String get noOtherChats;

  /// No description provided for @shareSendTo.
  ///
  /// In en, this message translates to:
  /// **'Send to…'**
  String get shareSendTo;

  /// No description provided for @shareSearch.
  ///
  /// In en, this message translates to:
  /// **'Search chats'**
  String get shareSearch;

  /// No description provided for @shareCaptionHint.
  ///
  /// In en, this message translates to:
  /// **'Add a caption…'**
  String get shareCaptionHint;

  /// No description provided for @shareMessageHint.
  ///
  /// In en, this message translates to:
  /// **'Message'**
  String get shareMessageHint;

  /// No description provided for @sharePickChat.
  ///
  /// In en, this message translates to:
  /// **'Choose a chat'**
  String get sharePickChat;

  /// No description provided for @shareSend.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get shareSend;

  /// No description provided for @shareSendCount.
  ///
  /// In en, this message translates to:
  /// **'{n, plural, =1{Send to 1 chat} other{Send to {n} chats}}'**
  String shareSendCount(int n);

  /// No description provided for @sharePhotos.
  ///
  /// In en, this message translates to:
  /// **'{n, plural, =1{Photo} other{{n} photos}}'**
  String sharePhotos(int n);

  /// No description provided for @shareVideos.
  ///
  /// In en, this message translates to:
  /// **'{n, plural, =1{Video} other{{n} videos}}'**
  String shareVideos(int n);

  /// No description provided for @shareFiles.
  ///
  /// In en, this message translates to:
  /// **'{n, plural, =1{1 file} other{{n} files}}'**
  String shareFiles(int n);

  /// No description provided for @shareSent.
  ///
  /// In en, this message translates to:
  /// **'Sent'**
  String get shareSent;

  /// No description provided for @shareNoChats.
  ///
  /// In en, this message translates to:
  /// **'No chats yet — start one first'**
  String get shareNoChats;

  /// No description provided for @shareNoAccount.
  ///
  /// In en, this message translates to:
  /// **'Sign in to Sinhron first, then share again.'**
  String get shareNoAccount;

  /// No description provided for @shareNothing.
  ///
  /// In en, this message translates to:
  /// **'Nothing to send: that app shared nothing Sinhron can open.'**
  String get shareNothing;

  /// No description provided for @videoUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Video unavailable'**
  String get videoUnavailable;

  /// No description provided for @videoPlay.
  ///
  /// In en, this message translates to:
  /// **'Play'**
  String get videoPlay;

  /// No description provided for @videoPause.
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get videoPause;

  /// No description provided for @videoSoundOn.
  ///
  /// In en, this message translates to:
  /// **'Sound on'**
  String get videoSoundOn;

  /// No description provided for @videoSoundOff.
  ///
  /// In en, this message translates to:
  /// **'Sound off'**
  String get videoSoundOff;

  /// No description provided for @viewerClose.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get viewerClose;

  /// No description provided for @showInChat.
  ///
  /// In en, this message translates to:
  /// **'Show in chat'**
  String get showInChat;

  /// No description provided for @forwarded.
  ///
  /// In en, this message translates to:
  /// **'Forwarded'**
  String get forwarded;

  /// No description provided for @couldNotForward.
  ///
  /// In en, this message translates to:
  /// **'Could not forward'**
  String get couldNotForward;

  /// No description provided for @decrypting.
  ///
  /// In en, this message translates to:
  /// **'Opening…'**
  String get decrypting;

  /// No description provided for @nOfM.
  ///
  /// In en, this message translates to:
  /// **'{n} of {m}'**
  String nOfM(int n, int m);

  /// No description provided for @share.
  ///
  /// In en, this message translates to:
  /// **'Share'**
  String get share;

  /// No description provided for @shared.
  ///
  /// In en, this message translates to:
  /// **'Shared'**
  String get shared;

  /// No description provided for @saveToPhotos.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get saveToPhotos;

  /// No description provided for @savedToPhotos.
  ///
  /// In en, this message translates to:
  /// **'Saved to Photos'**
  String get savedToPhotos;

  /// No description provided for @couldNotSave.
  ///
  /// In en, this message translates to:
  /// **'Could not save'**
  String get couldNotSave;

  /// No description provided for @quickCheck.
  ///
  /// In en, this message translates to:
  /// **'Quick check'**
  String get quickCheck;

  /// No description provided for @quickCheckBody.
  ///
  /// In en, this message translates to:
  /// **'Just to be sure the words are safe on paper. {n} of {m}.'**
  String quickCheckBody(int n, int m);

  /// No description provided for @whichWord.
  ///
  /// In en, this message translates to:
  /// **'Which is word #{n}?'**
  String whichWord(int n);

  /// No description provided for @wrongWord.
  ///
  /// In en, this message translates to:
  /// **'Not quite — have another look at word #{n} on your paper.'**
  String wrongWord(int n);

  /// No description provided for @showWordsAgain.
  ///
  /// In en, this message translates to:
  /// **'Show me the words again'**
  String get showWordsAgain;

  /// No description provided for @saveAccessTitle.
  ///
  /// In en, this message translates to:
  /// **'Keep access to your account'**
  String get saveAccessTitle;

  /// No description provided for @saveAccessBody.
  ///
  /// In en, this message translates to:
  /// **'Your account is 24 secret words. If this phone is lost, they bring the account back on a new one. We don’t have them — keep them where you won’t lose them.'**
  String get saveAccessBody;

  /// No description provided for @saveToPasswordsIos.
  ///
  /// In en, this message translates to:
  /// **'Save to iCloud Keychain'**
  String get saveToPasswordsIos;

  /// No description provided for @saveToPasswordsAndroid.
  ///
  /// In en, this message translates to:
  /// **'Save to password manager'**
  String get saveToPasswordsAndroid;

  /// No description provided for @savePasswordsHintIos.
  ///
  /// In en, this message translates to:
  /// **'One tap. Only Sinhron can read them — they aren’t in the Passwords app, and no website can ask for them. With iCloud Keychain on, they come to your new iPhone.'**
  String get savePasswordsHintIos;

  /// No description provided for @savePasswordsHintAndroid.
  ///
  /// In en, this message translates to:
  /// **'One tap. Google encrypts them and brings them to your new phone with your Google account.'**
  String get savePasswordsHintAndroid;

  /// No description provided for @passwordsFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn’t save to the password manager. Try again or write the words down.'**
  String get passwordsFailed;

  /// No description provided for @writeWordsAction.
  ///
  /// In en, this message translates to:
  /// **'Write the words down'**
  String get writeWordsAction;

  /// No description provided for @writeWordsRowHint.
  ///
  /// In en, this message translates to:
  /// **'On paper, or a sheet to print'**
  String get writeWordsRowHint;

  /// No description provided for @saveLater.
  ///
  /// In en, this message translates to:
  /// **'Later'**
  String get saveLater;

  /// No description provided for @saveLaterHint.
  ///
  /// In en, this message translates to:
  /// **'Until then the words are only on this phone. We’ll remind you in Settings.'**
  String get saveLaterHint;

  /// No description provided for @writeWordsTitle.
  ///
  /// In en, this message translates to:
  /// **'Write down the 24 words'**
  String get writeWordsTitle;

  /// No description provided for @writeWordsBody.
  ///
  /// In en, this message translates to:
  /// **'In this order, on paper. Keep it like a passport: anyone who reads these words can open your account.'**
  String get writeWordsBody;

  /// No description provided for @screenshotNote.
  ///
  /// In en, this message translates to:
  /// **'A screenshot isn’t a safe place: it goes to the cloud with your photos.'**
  String get screenshotNote;

  /// No description provided for @wordsWritten.
  ///
  /// In en, this message translates to:
  /// **'I’ve written them down'**
  String get wordsWritten;

  /// No description provided for @sheetAction.
  ///
  /// In en, this message translates to:
  /// **'Recovery sheet to print'**
  String get sheetAction;

  /// No description provided for @sheetTitle.
  ///
  /// In en, this message translates to:
  /// **'Sinhron — secret words'**
  String get sheetTitle;

  /// No description provided for @sheetHowTitle.
  ///
  /// In en, this message translates to:
  /// **'How to get your account back'**
  String get sheetHowTitle;

  /// No description provided for @sheetHowBody.
  ///
  /// In en, this message translates to:
  /// **'Install Sinhron on the new phone → “Sign in with secret words” → scan this code or type the 24 words in order.'**
  String get sheetHowBody;

  /// No description provided for @sheetWarning.
  ///
  /// In en, this message translates to:
  /// **'Anyone who sees these words owns your account. Print this sheet and delete the file. Don’t send it to anyone and don’t keep a photo of it in the cloud.'**
  String get sheetWarning;

  /// No description provided for @sheetScan.
  ///
  /// In en, this message translates to:
  /// **'Scan the recovery sheet'**
  String get sheetScan;

  /// No description provided for @sheetNotWords.
  ///
  /// In en, this message translates to:
  /// **'This code isn’t a recovery sheet.'**
  String get sheetNotWords;

  /// No description provided for @pasteFromPasswordsIos.
  ///
  /// In en, this message translates to:
  /// **'Paste from iCloud Keychain'**
  String get pasteFromPasswordsIos;

  /// No description provided for @pasteFromPasswordsAndroid.
  ///
  /// In en, this message translates to:
  /// **'Paste from password manager'**
  String get pasteFromPasswordsAndroid;

  /// No description provided for @reminderBody.
  ///
  /// In en, this message translates to:
  /// **'Your secret words are only on this phone. Save them so you don’t lose the account.'**
  String get reminderBody;

  /// No description provided for @reminderSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get reminderSave;

  /// No description provided for @wordsNotSaved.
  ///
  /// In en, this message translates to:
  /// **'Not saved'**
  String get wordsNotSaved;

  /// No description provided for @accessNotSavedTitle.
  ///
  /// In en, this message translates to:
  /// **'Access not saved'**
  String get accessNotSavedTitle;

  /// No description provided for @accessNotSavedBody.
  ///
  /// In en, this message translates to:
  /// **'The words are only on this phone. If something happens to it, the account can’t be brought back.'**
  String get accessNotSavedBody;

  /// No description provided for @accessSaveSection.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get accessSaveSection;

  /// No description provided for @accessSaveFooter.
  ///
  /// In en, this message translates to:
  /// **'Once saved, the words leave this phone — they’ll be where you saved them.'**
  String get accessSaveFooter;

  /// No description provided for @accessSavedTitle.
  ///
  /// In en, this message translates to:
  /// **'Access saved'**
  String get accessSavedTitle;

  /// No description provided for @accessSavedPasswordsIos.
  ///
  /// In en, this message translates to:
  /// **'In Passwords · {date}, as a website password — a website could ask for it. Move them below.'**
  String accessSavedPasswordsIos(String date);

  /// No description provided for @accessSavedKeychainIos.
  ///
  /// In en, this message translates to:
  /// **'In iCloud Keychain · {date}. Only Sinhron reads them; they move to a new iPhone with iCloud Keychain on.'**
  String accessSavedKeychainIos(String date);

  /// No description provided for @moveToKeychain.
  ///
  /// In en, this message translates to:
  /// **'Move to iCloud Keychain'**
  String get moveToKeychain;

  /// No description provided for @moveToKeychainFooter.
  ///
  /// In en, this message translates to:
  /// **'Pick the Sinhron entry: the words move to iCloud Keychain, and the old Passwords entry is deleted.'**
  String get moveToKeychainFooter;

  /// No description provided for @accessSavedPasswordsAndroid.
  ///
  /// In en, this message translates to:
  /// **'In the password manager · {date}. They come to a new phone with your Google account.'**
  String accessSavedPasswordsAndroid(String date);

  /// No description provided for @accessSavedPaper.
  ///
  /// In en, this message translates to:
  /// **'Written down · {date}. Keep the paper like a passport.'**
  String accessSavedPaper(String date);

  /// No description provided for @accessSavedSheet.
  ///
  /// In en, this message translates to:
  /// **'Recovery sheet · {date}. Print it and delete the file.'**
  String accessSavedSheet(String date);

  /// No description provided for @accessSavedChecked.
  ///
  /// In en, this message translates to:
  /// **'Checked · {date}. You have the right words.'**
  String accessSavedChecked(String date);

  /// No description provided for @accessSavedDone.
  ///
  /// In en, this message translates to:
  /// **'Saved'**
  String get accessSavedDone;

  /// No description provided for @phraseStatusAllWords.
  ///
  /// In en, this message translates to:
  /// **'24 words'**
  String get phraseStatusAllWords;

  /// No description provided for @secondDeviceSection.
  ///
  /// In en, this message translates to:
  /// **'Second device'**
  String get secondDeviceSection;

  /// No description provided for @secondDeviceCount.
  ///
  /// In en, this message translates to:
  /// **'Other devices: {n}'**
  String secondDeviceCount(int n);

  /// No description provided for @secondDeviceLink.
  ///
  /// In en, this message translates to:
  /// **'Link a second device'**
  String get secondDeviceLink;

  /// No description provided for @secondDeviceYes.
  ///
  /// In en, this message translates to:
  /// **'If something happens to this phone, your chats stay on your other device. But a new phone can still be added only with the secret words.'**
  String get secondDeviceYes;

  /// No description provided for @secondDeviceNo.
  ///
  /// In en, this message translates to:
  /// **'A second device (a tablet, another phone) keeps your chats if this phone is lost. It doesn’t replace the words: a new phone is added with them.'**
  String get secondDeviceNo;

  /// No description provided for @checkWordsTitle.
  ///
  /// In en, this message translates to:
  /// **'Check the words'**
  String get checkWordsTitle;

  /// No description provided for @checkWordsBody.
  ///
  /// In en, this message translates to:
  /// **'Enter your 24 secret words — the app compares them with this account. They aren’t stored.'**
  String get checkWordsBody;

  /// No description provided for @checkWordsAction.
  ///
  /// In en, this message translates to:
  /// **'Check'**
  String get checkWordsAction;

  /// No description provided for @wordsMatch.
  ///
  /// In en, this message translates to:
  /// **'Right — these are your words'**
  String get wordsMatch;

  /// No description provided for @wordsDontMatch.
  ///
  /// In en, this message translates to:
  /// **'These aren’t this account’s words'**
  String get wordsDontMatch;

  /// No description provided for @verifyTitle.
  ///
  /// In en, this message translates to:
  /// **'Check {name}'**
  String verifyTitle(String name);

  /// No description provided for @verifyNotYet.
  ///
  /// In en, this message translates to:
  /// **'This chat can’t be verified yet — send a message first.'**
  String get verifyNotYet;

  /// No description provided for @showNumber.
  ///
  /// In en, this message translates to:
  /// **'Show the number instead'**
  String get showNumber;

  /// No description provided for @verifyExplain.
  ///
  /// In en, this message translates to:
  /// **'Compare this number with the one on {name}’s phone — in person or on a call. If they match, nobody is in between and only you two read the chat.'**
  String verifyExplain(String name);

  /// No description provided for @clearVerification.
  ///
  /// In en, this message translates to:
  /// **'Clear verification'**
  String get clearVerification;

  /// No description provided for @markVerified.
  ///
  /// In en, this message translates to:
  /// **'Mark as verified'**
  String get markVerified;

  /// No description provided for @verifiedTitle.
  ///
  /// In en, this message translates to:
  /// **'Verified'**
  String get verifiedTitle;

  /// No description provided for @safetyChangedTitle.
  ///
  /// In en, this message translates to:
  /// **'Check number changed'**
  String get safetyChangedTitle;

  /// No description provided for @notVerifiedTitle.
  ///
  /// In en, this message translates to:
  /// **'Not verified yet'**
  String get notVerifiedTitle;

  /// No description provided for @unlockReason.
  ///
  /// In en, this message translates to:
  /// **'Unlock Sinhron'**
  String get unlockReason;

  /// No description provided for @appLocked.
  ///
  /// In en, this message translates to:
  /// **'Sinhron is locked'**
  String get appLocked;

  /// No description provided for @tapToUnlock.
  ///
  /// In en, this message translates to:
  /// **'Tap to unlock with Face ID or your passcode'**
  String get tapToUnlock;

  /// No description provided for @setPasscodeFirst.
  ///
  /// In en, this message translates to:
  /// **'Set a passcode on this iPhone first — App Lock uses it.'**
  String get setPasscodeFirst;

  /// No description provided for @turnOnAppLock.
  ///
  /// In en, this message translates to:
  /// **'Turn on App Lock'**
  String get turnOnAppLock;

  /// No description provided for @lockAgain.
  ///
  /// In en, this message translates to:
  /// **'Lock again'**
  String get lockAgain;

  /// No description provided for @appLockTitle.
  ///
  /// In en, this message translates to:
  /// **'App lock'**
  String get appLockTitle;

  /// No description provided for @lockSection.
  ///
  /// In en, this message translates to:
  /// **'Lock'**
  String get lockSection;

  /// No description provided for @appLockFooter.
  ///
  /// In en, this message translates to:
  /// **'When on, Sinhron asks for Face ID or your iPhone passcode when it opens. Your chats stay encrypted either way.'**
  String get appLockFooter;

  /// No description provided for @appLockToggle.
  ///
  /// In en, this message translates to:
  /// **'App Lock'**
  String get appLockToggle;

  /// No description provided for @appSwitcher.
  ///
  /// In en, this message translates to:
  /// **'App switcher'**
  String get appSwitcher;

  /// No description provided for @appSwitcherFooter.
  ///
  /// In en, this message translates to:
  /// **'Covers your chats with a blur when you switch apps, so they don’t show in the app switcher.'**
  String get appSwitcherFooter;

  /// No description provided for @hideInSwitcher.
  ///
  /// In en, this message translates to:
  /// **'Hide chats in app switcher'**
  String get hideInSwitcher;

  /// No description provided for @privacyTitle.
  ///
  /// In en, this message translates to:
  /// **'Privacy & security'**
  String get privacyTitle;

  /// No description provided for @whatOthersSee.
  ///
  /// In en, this message translates to:
  /// **'What others see'**
  String get whatOthersSee;

  /// No description provided for @whatOthersSeeFooter.
  ///
  /// In en, this message translates to:
  /// **'Turning off read ticks or typing also hides them from you — fair both ways. “Online” and “last seen” go only to your contacts — people you have a personal chat with — and only while this is on. Turning it off makes them forget when they last saw you.'**
  String get whatOthersSeeFooter;

  /// No description provided for @readReceipts.
  ///
  /// In en, this message translates to:
  /// **'Read ticks'**
  String get readReceipts;

  /// No description provided for @typingIndicators.
  ///
  /// In en, this message translates to:
  /// **'Typing indicators'**
  String get typingIndicators;

  /// No description provided for @onlineStatus.
  ///
  /// In en, this message translates to:
  /// **'Online status'**
  String get onlineStatus;

  /// No description provided for @showOnline.
  ///
  /// In en, this message translates to:
  /// **'Show when I’m online'**
  String get showOnline;

  /// No description provided for @onlyContacts.
  ///
  /// In en, this message translates to:
  /// **'Contacts only'**
  String get onlyContacts;

  /// No description provided for @lastSeenJustNow.
  ///
  /// In en, this message translates to:
  /// **'last seen just now'**
  String get lastSeenJustNow;

  /// No description provided for @lastSeenMinutes.
  ///
  /// In en, this message translates to:
  /// **'{n, plural, =1{last seen 1 minute ago} other{last seen {n} minutes ago}}'**
  String lastSeenMinutes(int n);

  /// No description provided for @lastSeenToday.
  ///
  /// In en, this message translates to:
  /// **'last seen today at {time}'**
  String lastSeenToday(String time);

  /// No description provided for @lastSeenYesterday.
  ///
  /// In en, this message translates to:
  /// **'last seen yesterday at {time}'**
  String lastSeenYesterday(String time);

  /// No description provided for @lastSeenDate.
  ///
  /// In en, this message translates to:
  /// **'last seen {date}'**
  String lastSeenDate(String date);

  /// No description provided for @disappearingMessages.
  ///
  /// In en, this message translates to:
  /// **'Disappearing messages'**
  String get disappearingMessages;

  /// No description provided for @disappearingFooter.
  ///
  /// In en, this message translates to:
  /// **'Set it per chat: press and hold the chat’s name at the top. Messages then delete themselves on both phones — text and photos alike.'**
  String get disappearingFooter;

  /// No description provided for @timer.
  ///
  /// In en, this message translates to:
  /// **'Timer'**
  String get timer;

  /// No description provided for @links.
  ///
  /// In en, this message translates to:
  /// **'Links'**
  String get links;

  /// No description provided for @linksFooter.
  ///
  /// In en, this message translates to:
  /// **'Your phone fetches the link’s picture and title when you send it: the site learns it was opened from your phone, never who you’re writing to. Off by default.'**
  String get linksFooter;

  /// No description provided for @linkPreviews.
  ///
  /// In en, this message translates to:
  /// **'Link previews'**
  String get linkPreviews;

  /// No description provided for @thisDevice.
  ///
  /// In en, this message translates to:
  /// **'This device'**
  String get thisDevice;

  /// No description provided for @on.
  ///
  /// In en, this message translates to:
  /// **'On'**
  String get on;

  /// No description provided for @e2eTitle.
  ///
  /// In en, this message translates to:
  /// **'Encrypted'**
  String get e2eTitle;

  /// No description provided for @e2eAlways.
  ///
  /// In en, this message translates to:
  /// **'Always on. Not a setting.'**
  String get e2eAlways;

  /// No description provided for @e2eBody.
  ///
  /// In en, this message translates to:
  /// **'Your messages, calls and files can be read only on your devices and the people you send them to. Your server sees encrypted data and delivery timing — never content, never who you talk to.'**
  String get e2eBody;

  /// No description provided for @chipKeys.
  ///
  /// In en, this message translates to:
  /// **'Every message has its own key'**
  String get chipKeys;

  /// No description provided for @chipOld.
  ///
  /// In en, this message translates to:
  /// **'Old messages stay safe'**
  String get chipOld;

  /// No description provided for @chipHeal.
  ///
  /// In en, this message translates to:
  /// **'Protection recovers by itself after a break-in'**
  String get chipHeal;

  /// No description provided for @appearance.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get appearance;

  /// No description provided for @theme.
  ///
  /// In en, this message translates to:
  /// **'Theme'**
  String get theme;

  /// No description provided for @accentColour.
  ///
  /// In en, this message translates to:
  /// **'Accent colour'**
  String get accentColour;

  /// No description provided for @chatWallpaper.
  ///
  /// In en, this message translates to:
  /// **'Chat wallpaper'**
  String get chatWallpaper;

  /// No description provided for @wallpaperFooter.
  ///
  /// In en, this message translates to:
  /// **'Your own photo stays on this device only.'**
  String get wallpaperFooter;

  /// No description provided for @previewIn.
  ///
  /// In en, this message translates to:
  /// **'Hi! How are you? 👋'**
  String get previewIn;

  /// No description provided for @unavailable.
  ///
  /// In en, this message translates to:
  /// **'Unavailable'**
  String get unavailable;

  /// No description provided for @file.
  ///
  /// In en, this message translates to:
  /// **'File'**
  String get file;

  /// No description provided for @documentUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Document unavailable'**
  String get documentUnavailable;

  /// No description provided for @couldNotOpen.
  ///
  /// In en, this message translates to:
  /// **'Could not open — tap to retry'**
  String get couldNotOpen;

  /// No description provided for @photoUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Photo unavailable'**
  String get photoUnavailable;

  /// No description provided for @whatPhoto.
  ///
  /// In en, this message translates to:
  /// **'photo'**
  String get whatPhoto;

  /// No description provided for @whatVoice.
  ///
  /// In en, this message translates to:
  /// **'voice message'**
  String get whatVoice;

  /// No description provided for @whatVideo.
  ///
  /// In en, this message translates to:
  /// **'video'**
  String get whatVideo;

  /// No description provided for @notSentRetry.
  ///
  /// In en, this message translates to:
  /// **'Not sent: {what} — tap to retry'**
  String notSentRetry(String what);

  /// No description provided for @sendingPercent.
  ///
  /// In en, this message translates to:
  /// **'Sending {what}… {p}%'**
  String sendingPercent(String what, int p);

  /// No description provided for @preparing.
  ///
  /// In en, this message translates to:
  /// **'Preparing {what}…'**
  String preparing(String what);

  /// No description provided for @sending.
  ///
  /// In en, this message translates to:
  /// **'Sending {what}…'**
  String sending(String what);

  /// No description provided for @lockImmediately.
  ///
  /// In en, this message translates to:
  /// **'Immediately'**
  String get lockImmediately;

  /// No description provided for @lockAfterMinutes.
  ///
  /// In en, this message translates to:
  /// **'{n, plural, =1{After 1 minute} other{After {n} minutes}}'**
  String lockAfterMinutes(int n);

  /// No description provided for @lockAfterHour.
  ///
  /// In en, this message translates to:
  /// **'After 1 hour'**
  String get lockAfterHour;

  /// No description provided for @themeSystem.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get themeSystem;

  /// No description provided for @themeLight.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get themeLight;

  /// No description provided for @themeDark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get themeDark;

  /// No description provided for @themeOled.
  ///
  /// In en, this message translates to:
  /// **'Black (OLED)'**
  String get themeOled;

  /// No description provided for @wallNone.
  ///
  /// In en, this message translates to:
  /// **'None'**
  String get wallNone;

  /// No description provided for @wallDawn.
  ///
  /// In en, this message translates to:
  /// **'Dawn'**
  String get wallDawn;

  /// No description provided for @wallMist.
  ///
  /// In en, this message translates to:
  /// **'Mist'**
  String get wallMist;

  /// No description provided for @wallDusk.
  ///
  /// In en, this message translates to:
  /// **'Dusk'**
  String get wallDusk;

  /// No description provided for @wallDots.
  ///
  /// In en, this message translates to:
  /// **'Dots'**
  String get wallDots;

  /// No description provided for @wallWaves.
  ///
  /// In en, this message translates to:
  /// **'Waves'**
  String get wallWaves;

  /// No description provided for @wallPhoto.
  ///
  /// In en, this message translates to:
  /// **'Photo'**
  String get wallPhoto;

  /// No description provided for @yourName.
  ///
  /// In en, this message translates to:
  /// **'Your name'**
  String get yourName;

  /// No description provided for @keyNotCreated.
  ///
  /// In en, this message translates to:
  /// **'Address not ready yet'**
  String get keyNotCreated;

  /// No description provided for @keyFingerprint.
  ///
  /// In en, this message translates to:
  /// **'Address {fp}'**
  String keyFingerprint(String fp);

  /// No description provided for @language.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get language;

  /// No description provided for @langSystem.
  ///
  /// In en, this message translates to:
  /// **'As on phone'**
  String get langSystem;

  /// No description provided for @langEn.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get langEn;

  /// No description provided for @langRu.
  ///
  /// In en, this message translates to:
  /// **'Русский'**
  String get langRu;

  /// No description provided for @privacySection.
  ///
  /// In en, this message translates to:
  /// **'Privacy'**
  String get privacySection;

  /// No description provided for @privacySectionFooter.
  ///
  /// In en, this message translates to:
  /// **'Your chats are always encrypted — only you and the people in them can read them. These options control what other people and your server can see about you.'**
  String get privacySectionFooter;

  /// No description provided for @review.
  ///
  /// In en, this message translates to:
  /// **'Review'**
  String get review;

  /// No description provided for @linkedDevices.
  ///
  /// In en, this message translates to:
  /// **'Devices'**
  String get linkedDevices;

  /// No description provided for @accountKey.
  ///
  /// In en, this message translates to:
  /// **'Secret words'**
  String get accountKey;

  /// No description provided for @notifications.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get notifications;

  /// No description provided for @notificationsFooter.
  ///
  /// In en, this message translates to:
  /// **'When Sinhron is closed, an iPhone shows only “New message” — your server can’t read messages.'**
  String get notificationsFooter;

  /// No description provided for @soundsVibration.
  ///
  /// In en, this message translates to:
  /// **'Sounds & vibrations'**
  String get soundsVibration;

  /// No description provided for @textSize.
  ///
  /// In en, this message translates to:
  /// **'Text size'**
  String get textSize;

  /// No description provided for @asInIphone.
  ///
  /// In en, this message translates to:
  /// **'As in iPhone settings'**
  String get asInIphone;

  /// No description provided for @wallpaper.
  ///
  /// In en, this message translates to:
  /// **'Wallpaper'**
  String get wallpaper;

  /// No description provided for @storage.
  ///
  /// In en, this message translates to:
  /// **'Storage'**
  String get storage;

  /// No description provided for @server.
  ///
  /// In en, this message translates to:
  /// **'Server'**
  String get server;

  /// No description provided for @serverFooter.
  ///
  /// In en, this message translates to:
  /// **'The server is the computer that carries your messages to other people. Its owner can see when messages are delivered, never what’s inside them.'**
  String get serverFooter;

  /// No description provided for @notConnected.
  ///
  /// In en, this message translates to:
  /// **'Not connected'**
  String get notConnected;

  /// No description provided for @about.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get about;

  /// No description provided for @updateAvailableTitle.
  ///
  /// In en, this message translates to:
  /// **'Update {version} is available'**
  String updateAvailableTitle(String version);

  /// No description provided for @updateAvailableBody.
  ///
  /// In en, this message translates to:
  /// **'It downloads right here; then Android asks you to tap Install. Chats and keys stay.'**
  String get updateAvailableBody;

  /// No description provided for @updateAction.
  ///
  /// In en, this message translates to:
  /// **'Update'**
  String get updateAction;

  /// No description provided for @updateDownloading.
  ///
  /// In en, this message translates to:
  /// **'Downloading the update… {percent}%'**
  String updateDownloading(int percent);

  /// No description provided for @updateReadyTitle.
  ///
  /// In en, this message translates to:
  /// **'The update is downloaded'**
  String get updateReadyTitle;

  /// No description provided for @updateReadyBody.
  ///
  /// In en, this message translates to:
  /// **'Tap Install — Android will ask once more.'**
  String get updateReadyBody;

  /// No description provided for @updateInstall.
  ///
  /// In en, this message translates to:
  /// **'Install'**
  String get updateInstall;

  /// No description provided for @updateFailedOffline.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t download the update. Check the internet and try again.'**
  String get updateFailedOffline;

  /// No description provided for @updateFailedBadFile.
  ///
  /// In en, this message translates to:
  /// **'The update file didn\'t pass the safety check, so it won\'t be installed. Try again later.'**
  String get updateFailedBadFile;

  /// No description provided for @updateFailedInstaller.
  ///
  /// In en, this message translates to:
  /// **'Android didn\'t open the installer. Try again.'**
  String get updateFailedInstaller;

  /// No description provided for @updateRetry.
  ///
  /// In en, this message translates to:
  /// **'Try again'**
  String get updateRetry;

  /// No description provided for @updateLater.
  ///
  /// In en, this message translates to:
  /// **'Later'**
  String get updateLater;

  /// No description provided for @updateCheck.
  ///
  /// In en, this message translates to:
  /// **'Check for updates'**
  String get updateCheck;

  /// No description provided for @updateCheckHint.
  ///
  /// In en, this message translates to:
  /// **'New versions come from our server'**
  String get updateCheckHint;

  /// No description provided for @updateChecking.
  ///
  /// In en, this message translates to:
  /// **'Checking…'**
  String get updateChecking;

  /// No description provided for @updateUpToDate.
  ///
  /// In en, this message translates to:
  /// **'You have the latest version'**
  String get updateUpToDate;

  /// No description provided for @updateOffline.
  ///
  /// In en, this message translates to:
  /// **'No connection to the server — try later'**
  String get updateOffline;

  /// No description provided for @updateNewVersion.
  ///
  /// In en, this message translates to:
  /// **'{version} available'**
  String updateNewVersion(String version);

  /// No description provided for @updatePermissionExplain.
  ///
  /// In en, this message translates to:
  /// **'Android will now ask whether Sinhron may install apps. Tap Settings, turn on “Allow from this source” and go back — the installation carries on; then tap Install. It asks only the first time.'**
  String get updatePermissionExplain;

  /// No description provided for @updateContinue.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get updateContinue;

  /// No description provided for @clipboardClears.
  ///
  /// In en, this message translates to:
  /// **'Clipboard auto-clears 60s after copy'**
  String get clipboardClears;

  /// No description provided for @copied.
  ///
  /// In en, this message translates to:
  /// **'Copied'**
  String get copied;

  /// No description provided for @copyPhrase.
  ///
  /// In en, this message translates to:
  /// **'Copy the words'**
  String get copyPhrase;

  /// No description provided for @tagline.
  ///
  /// In en, this message translates to:
  /// **'Messages that stay between you.'**
  String get tagline;

  /// No description provided for @getStarted.
  ///
  /// In en, this message translates to:
  /// **'Get started'**
  String get getStarted;

  /// No description provided for @linkDevice.
  ///
  /// In en, this message translates to:
  /// **'Link a device'**
  String get linkDevice;

  /// No description provided for @restoreFromKey.
  ///
  /// In en, this message translates to:
  /// **'Sign in with secret words →'**
  String get restoreFromKey;

  /// No description provided for @pickServer.
  ///
  /// In en, this message translates to:
  /// **'Pick a server'**
  String get pickServer;

  /// No description provided for @pickServerBody.
  ///
  /// In en, this message translates to:
  /// **'A server is the computer that carries your messages to other people. Your team’s, a friend’s or your own will do. It can’t read what you send.'**
  String get pickServerBody;

  /// No description provided for @serverHowToGet.
  ///
  /// In en, this message translates to:
  /// **'Whoever set up the server gives you its address. Type it, or scan the QR code they showed you.'**
  String get serverHowToGet;

  /// No description provided for @serverScanQr.
  ///
  /// In en, this message translates to:
  /// **'Scan server QR code'**
  String get serverScanQr;

  /// No description provided for @serverInvalid.
  ///
  /// In en, this message translates to:
  /// **'That doesn’t look like a server address — for example sinhron.example.com.'**
  String get serverInvalid;

  /// No description provided for @serverNotSinhron.
  ///
  /// In en, this message translates to:
  /// **'Something answered at this address, but it isn’t a Sinhron server.'**
  String get serverNotSinhron;

  /// No description provided for @serverUnreachable.
  ///
  /// In en, this message translates to:
  /// **'The server isn’t answering. Check the address and your connection.'**
  String get serverUnreachable;

  /// Server step: saving the address to local storage failed
  ///
  /// In en, this message translates to:
  /// **'Couldn’t save this on the phone — the app’s storage didn’t open. Close the app and open it again.'**
  String get serverNotSaved;

  /// No description provided for @serverContinueAnyway.
  ///
  /// In en, this message translates to:
  /// **'Continue anyway'**
  String get serverContinueAnyway;

  /// No description provided for @pairNoServer.
  ///
  /// In en, this message translates to:
  /// **'Choose the server first — go back one step.'**
  String get pairNoServer;

  /// No description provided for @inviteToken.
  ///
  /// In en, this message translates to:
  /// **'Invite code'**
  String get inviteToken;

  /// No description provided for @pasteInvite.
  ///
  /// In en, this message translates to:
  /// **'paste your invite code'**
  String get pasteInvite;

  /// No description provided for @inviteAuto.
  ///
  /// In en, this message translates to:
  /// **'Filled in automatically from your invite link.'**
  String get inviteAuto;

  /// No description provided for @continueBtn.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get continueBtn;

  /// No description provided for @yourProfile.
  ///
  /// In en, this message translates to:
  /// **'Your profile'**
  String get yourProfile;

  /// No description provided for @profileBody.
  ///
  /// In en, this message translates to:
  /// **'Name your contacts will see. You can change this any time.'**
  String get profileBody;

  /// No description provided for @nameLabel.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get nameLabel;

  /// No description provided for @nameHint.
  ///
  /// In en, this message translates to:
  /// **'How you appear to contacts'**
  String get nameHint;

  /// No description provided for @settingUp.
  ///
  /// In en, this message translates to:
  /// **'Setting up your device'**
  String get settingUp;

  /// No description provided for @inApp.
  ///
  /// In en, this message translates to:
  /// **'In the app'**
  String get inApp;

  /// No description provided for @vibration.
  ///
  /// In en, this message translates to:
  /// **'Vibration'**
  String get vibration;

  /// No description provided for @inChatSounds.
  ///
  /// In en, this message translates to:
  /// **'In-chat sounds'**
  String get inChatSounds;

  /// No description provided for @pushNotifications.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get pushNotifications;

  /// No description provided for @comingSoon.
  ///
  /// In en, this message translates to:
  /// **'App Store version'**
  String get comingSoon;

  /// No description provided for @setupConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting to {host}'**
  String setupConnecting(String host);

  /// No description provided for @setupIdentity.
  ///
  /// In en, this message translates to:
  /// **'Checking this phone'**
  String get setupIdentity;

  /// No description provided for @setupGroups.
  ///
  /// In en, this message translates to:
  /// **'Joining your groups'**
  String get setupGroups;

  /// No description provided for @setupContacts.
  ///
  /// In en, this message translates to:
  /// **'Getting your chats ready'**
  String get setupContacts;

  /// No description provided for @mediaLoadError.
  ///
  /// In en, this message translates to:
  /// **'Could not load media'**
  String get mediaLoadError;

  /// No description provided for @noVoiceYet.
  ///
  /// In en, this message translates to:
  /// **'No voice messages yet'**
  String get noVoiceYet;

  /// No description provided for @noLinksYet.
  ///
  /// In en, this message translates to:
  /// **'No links yet'**
  String get noLinksYet;

  /// No description provided for @sharedMediaMedia.
  ///
  /// In en, this message translates to:
  /// **'Media'**
  String get sharedMediaMedia;

  /// No description provided for @sharedMediaFiles.
  ///
  /// In en, this message translates to:
  /// **'Files'**
  String get sharedMediaFiles;

  /// No description provided for @noMediaYet.
  ///
  /// In en, this message translates to:
  /// **'No photos or videos yet'**
  String get noMediaYet;

  /// No description provided for @noFilesYet.
  ///
  /// In en, this message translates to:
  /// **'No files yet'**
  String get noFilesYet;

  /// No description provided for @searchContacts.
  ///
  /// In en, this message translates to:
  /// **'Search contacts'**
  String get searchContacts;

  /// No description provided for @contactsEmpty.
  ///
  /// In en, this message translates to:
  /// **'No contacts yet. Add someone by their QR code, invite link or address — they stay here even if you delete the chat.'**
  String get contactsEmpty;

  /// No description provided for @recent.
  ///
  /// In en, this message translates to:
  /// **'Recent'**
  String get recent;

  /// No description provided for @contactsFooter.
  ///
  /// In en, this message translates to:
  /// **'Your contacts stay on this phone only — your server can’t see who you talk to. Start a chat with a QR code or an address.'**
  String get contactsFooter;

  /// No description provided for @noContactNamed.
  ///
  /// In en, this message translates to:
  /// **'No contact named “{q}”'**
  String noContactNamed(String q);

  /// No description provided for @noContactHint.
  ///
  /// In en, this message translates to:
  /// **'Try a different name or invite them with a QR code.'**
  String get noContactHint;

  /// No description provided for @newChat.
  ///
  /// In en, this message translates to:
  /// **'New chat'**
  String get newChat;

  /// No description provided for @newGroup.
  ///
  /// In en, this message translates to:
  /// **'New group'**
  String get newGroup;

  /// No description provided for @inviteByQr.
  ///
  /// In en, this message translates to:
  /// **'Invite by QR'**
  String get inviteByQr;

  /// No description provided for @scanQr.
  ///
  /// In en, this message translates to:
  /// **'Scan QR'**
  String get scanQr;

  /// No description provided for @pasteKey.
  ///
  /// In en, this message translates to:
  /// **'Paste address'**
  String get pasteKey;

  /// No description provided for @pasteFromClipboard.
  ///
  /// In en, this message translates to:
  /// **'Paste'**
  String get pasteFromClipboard;

  /// No description provided for @pasteKeyCount.
  ///
  /// In en, this message translates to:
  /// **'{count} of 64 characters'**
  String pasteKeyCount(int count);

  /// No description provided for @pasteKeyReady.
  ///
  /// In en, this message translates to:
  /// **'Address looks right'**
  String get pasteKeyReady;

  /// No description provided for @startEncrypted.
  ///
  /// In en, this message translates to:
  /// **'Start encrypted chat'**
  String get startEncrypted;

  /// No description provided for @pasteKeyHint.
  ///
  /// In en, this message translates to:
  /// **'Paste the other person’s address — 64 characters. They find it in My profile → Copy address. They need to be online to get the invite.'**
  String get pasteKeyHint;

  /// No description provided for @keyHint.
  ///
  /// In en, this message translates to:
  /// **'64 characters'**
  String get keyHint;

  /// No description provided for @sendingInvite.
  ///
  /// In en, this message translates to:
  /// **'Sending invite…'**
  String get sendingInvite;

  /// No description provided for @startChat.
  ///
  /// In en, this message translates to:
  /// **'Start chat'**
  String get startChat;

  /// No description provided for @noEmailV.
  ///
  /// In en, this message translates to:
  /// **'we never ask for one'**
  String get noEmailV;

  /// No description provided for @skip.
  ///
  /// In en, this message translates to:
  /// **'Skip'**
  String get skip;

  /// No description provided for @welcome.
  ///
  /// In en, this message translates to:
  /// **'Welcome'**
  String get welcome;

  /// No description provided for @privateByDefault.
  ///
  /// In en, this message translates to:
  /// **'Private by default.'**
  String get privateByDefault;

  /// No description provided for @splash1Body.
  ///
  /// In en, this message translates to:
  /// **'Sinhron encrypts everything from the very first message. Your messages, calls and files can be read only on your devices and by the people you send them to.'**
  String get splash1Body;

  /// No description provided for @splash2Eyebrow.
  ///
  /// In en, this message translates to:
  /// **'Nothing about you'**
  String get splash2Eyebrow;

  /// No description provided for @splash2Title.
  ///
  /// In en, this message translates to:
  /// **'No email, no phone, no password.'**
  String get splash2Title;

  /// No description provided for @noEmail.
  ///
  /// In en, this message translates to:
  /// **'No email'**
  String get noEmail;

  /// No description provided for @noPhone.
  ///
  /// In en, this message translates to:
  /// **'No phone number'**
  String get noPhone;

  /// No description provided for @noPhoneV.
  ///
  /// In en, this message translates to:
  /// **'people add you by QR code or link'**
  String get noPhoneV;

  /// No description provided for @noPassword.
  ///
  /// In en, this message translates to:
  /// **'No password'**
  String get noPassword;

  /// No description provided for @noPasswordV.
  ///
  /// In en, this message translates to:
  /// **'24 secret words instead'**
  String get noPasswordV;

  /// No description provided for @ownKey.
  ///
  /// In en, this message translates to:
  /// **'Only you have the words'**
  String get ownKey;

  /// No description provided for @ownKeyV.
  ///
  /// In en, this message translates to:
  /// **'lose the words, lose the account'**
  String get ownKeyV;

  /// No description provided for @selfHosted.
  ///
  /// In en, this message translates to:
  /// **'Your server'**
  String get selfHosted;

  /// No description provided for @serverTrust.
  ///
  /// In en, this message translates to:
  /// **'Sinhron runs on a server you trust.'**
  String get serverTrust;

  /// No description provided for @serverRun.
  ///
  /// In en, this message translates to:
  /// **'Your team, your company, or you can run one. '**
  String get serverRun;

  /// No description provided for @serverData.
  ///
  /// In en, this message translates to:
  /// **'. Your data lives there and nowhere else — not with us, not with anyone.'**
  String get serverData;

  /// No description provided for @a11ySearch.
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get a11ySearch;

  /// No description provided for @a11yUnread.
  ///
  /// In en, this message translates to:
  /// **'{n} unread'**
  String a11yUnread(int n);

  /// No description provided for @a11yBack.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get a11yBack;

  /// No description provided for @a11yVideoCall.
  ///
  /// In en, this message translates to:
  /// **'Video call'**
  String get a11yVideoCall;

  /// No description provided for @a11yAttach.
  ///
  /// In en, this message translates to:
  /// **'Attach'**
  String get a11yAttach;

  /// No description provided for @a11yCloseAttach.
  ///
  /// In en, this message translates to:
  /// **'Close attachments'**
  String get a11yCloseAttach;

  /// No description provided for @cancelSending.
  ///
  /// In en, this message translates to:
  /// **'Cancel sending'**
  String get cancelSending;

  /// No description provided for @splitPickChat.
  ///
  /// In en, this message translates to:
  /// **'Choose a chat'**
  String get splitPickChat;

  /// No description provided for @splitPickSetting.
  ///
  /// In en, this message translates to:
  /// **'Choose a section'**
  String get splitPickSetting;

  /// No description provided for @splitPickContact.
  ///
  /// In en, this message translates to:
  /// **'Choose a contact'**
  String get splitPickContact;

  /// No description provided for @splitPickCall.
  ///
  /// In en, this message translates to:
  /// **'Choose a call to open its chat'**
  String get splitPickCall;

  /// No description provided for @a11yOpenPhoto.
  ///
  /// In en, this message translates to:
  /// **'Open photo'**
  String get a11yOpenPhoto;

  /// No description provided for @typingOne.
  ///
  /// In en, this message translates to:
  /// **'{name} is typing…'**
  String typingOne(String name);

  /// No description provided for @typingTwo.
  ///
  /// In en, this message translates to:
  /// **'{a} and {b} are typing…'**
  String typingTwo(String a, String b);

  /// No description provided for @typingMany.
  ///
  /// In en, this message translates to:
  /// **'{count} people are typing…'**
  String typingMany(int count);

  /// No description provided for @blockedChatNote.
  ///
  /// In en, this message translates to:
  /// **'You blocked {name}: their messages and calls aren\'t shown, and they no longer see your photo or when you\'re online.'**
  String blockedChatNote(String name);

  /// No description provided for @a11ySend.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get a11ySend;

  /// No description provided for @a11yRecord.
  ///
  /// In en, this message translates to:
  /// **'Hold to record a voice message. Tap to switch to video'**
  String get a11yRecord;

  /// No description provided for @a11yRecordVideo.
  ///
  /// In en, this message translates to:
  /// **'Hold to record a video message. Tap to switch to voice'**
  String get a11yRecordVideo;

  /// No description provided for @videoMessage.
  ///
  /// In en, this message translates to:
  /// **'Video message'**
  String get videoMessage;

  /// No description provided for @videoNoteCropFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t cut the video down to the circle, so it wasn\'t sent. Please record it again.'**
  String get videoNoteCropFailed;

  /// No description provided for @whatVideoNote.
  ///
  /// In en, this message translates to:
  /// **'video message'**
  String get whatVideoNote;

  /// No description provided for @holdToRecordVoice.
  ///
  /// In en, this message translates to:
  /// **'Hold to record a voice message, tap for video'**
  String get holdToRecordVoice;

  /// No description provided for @holdToRecordVideo.
  ///
  /// In en, this message translates to:
  /// **'Hold to record a video message, tap for voice'**
  String get holdToRecordVideo;

  /// No description provided for @errCameraMic.
  ///
  /// In en, this message translates to:
  /// **'Allow the camera and microphone in Settings to record video messages'**
  String get errCameraMic;

  /// No description provided for @a11yVideoNotePlay.
  ///
  /// In en, this message translates to:
  /// **'Video message, {duration}. Tap to play with sound'**
  String a11yVideoNotePlay(String duration);

  /// No description provided for @a11yVoiceSeek.
  ///
  /// In en, this message translates to:
  /// **'Playback position. Drag to rewind'**
  String get a11yVoiceSeek;

  /// No description provided for @a11yEmoji.
  ///
  /// In en, this message translates to:
  /// **'Emoji'**
  String get a11yEmoji;

  /// No description provided for @a11yMessageFrom.
  ///
  /// In en, this message translates to:
  /// **'{name}, {time}'**
  String a11yMessageFrom(String name, String time);

  /// No description provided for @a11yReplyTo.
  ///
  /// In en, this message translates to:
  /// **'reply to: {text}'**
  String a11yReplyTo(String text);

  /// No description provided for @a11yReactions.
  ///
  /// In en, this message translates to:
  /// **'reactions: {list}'**
  String a11yReactions(String list);

  /// No description provided for @a11yMessageHint.
  ///
  /// In en, this message translates to:
  /// **'Double tap and hold for options'**
  String get a11yMessageHint;

  /// No description provided for @a11yPinned.
  ///
  /// In en, this message translates to:
  /// **'pinned'**
  String get a11yPinned;

  /// No description provided for @a11yMuted.
  ///
  /// In en, this message translates to:
  /// **'muted'**
  String get a11yMuted;

  /// No description provided for @a11yDraft.
  ///
  /// In en, this message translates to:
  /// **'draft: {text}'**
  String a11yDraft(String text);

  /// No description provided for @a11yReact.
  ///
  /// In en, this message translates to:
  /// **'React with a heart'**
  String get a11yReact;

  /// No description provided for @bannerNewMessage.
  ///
  /// In en, this message translates to:
  /// **'New message'**
  String get bannerNewMessage;

  /// ADR-066 — reply from a notification
  ///
  /// In en, this message translates to:
  /// **'Reply'**
  String get notificationReply;

  /// ADR-066 — reply from a notification
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get notificationReplySend;

  /// ADR-066 — reply from a notification
  ///
  /// In en, this message translates to:
  /// **'Message'**
  String get notificationReplyPlaceholder;

  /// ADR-066 — reply from a notification
  ///
  /// In en, this message translates to:
  /// **'Your reply will go once Sinhron connects'**
  String get notificationReplyLater;

  /// ADR-066 — reply from a notification
  ///
  /// In en, this message translates to:
  /// **'Your reply will go when you open Sinhron'**
  String get notificationReplyOnOpen;

  /// ADR-066 — reply from a notification
  ///
  /// In en, this message translates to:
  /// **'Reply not sent — open the chat'**
  String get notificationReplyFailed;

  /// ADR-071 — a quiet notification for a stranger's message: no name, no text
  ///
  /// In en, this message translates to:
  /// **'New message request'**
  String get notificationNewRequest;

  /// No description provided for @bannerHint.
  ///
  /// In en, this message translates to:
  /// **'Opens the chat'**
  String get bannerHint;

  /// No description provided for @inAppBanners.
  ///
  /// In en, this message translates to:
  /// **'Banners in the app'**
  String get inAppBanners;

  /// No description provided for @bannerPreview.
  ///
  /// In en, this message translates to:
  /// **'Show message text'**
  String get bannerPreview;

  /// No description provided for @bannersFooter.
  ///
  /// In en, this message translates to:
  /// **'When a message comes into another chat, a banner appears at the top. Tap to open, swipe up to hide. Muted and archived chats stay quiet.'**
  String get bannersFooter;

  /// No description provided for @iconBadge.
  ///
  /// In en, this message translates to:
  /// **'Unread count on app icon'**
  String get iconBadge;

  /// No description provided for @unlockTitle.
  ///
  /// In en, this message translates to:
  /// **'Unlock Sinhron'**
  String get unlockTitle;

  /// No description provided for @unlockBody.
  ///
  /// In en, this message translates to:
  /// **'Your chats on this phone are encrypted. Enter your 24 secret words to open them.'**
  String get unlockBody;

  /// No description provided for @reconnectTitle.
  ///
  /// In en, this message translates to:
  /// **'Reconnect your account'**
  String get reconnectTitle;

  /// No description provided for @reconnectBody.
  ///
  /// In en, this message translates to:
  /// **'To reach your server again, enter your 24 secret words. You only need to do this once on this phone.'**
  String get reconnectBody;

  /// No description provided for @unlockHint.
  ///
  /// In en, this message translates to:
  /// **'24 words, separated by spaces'**
  String get unlockHint;

  /// No description provided for @unlockAction.
  ///
  /// In en, this message translates to:
  /// **'Unlock'**
  String get unlockAction;

  /// No description provided for @unlockPhraseNote.
  ///
  /// In en, this message translates to:
  /// **'The words never leave the phone and aren’t stored — the phone keeps only a key made from them, in the protected iPhone Keychain.'**
  String get unlockPhraseNote;

  /// No description provided for @unlockInvalidPhrase.
  ///
  /// In en, this message translates to:
  /// **'Those don’t look like your secret words — check the words and their order.'**
  String get unlockInvalidPhrase;

  /// No description provided for @unlockWrongPhrase.
  ///
  /// In en, this message translates to:
  /// **'These words don’t match the account on this phone.'**
  String get unlockWrongPhrase;

  /// No description provided for @eraseAndStartOver.
  ///
  /// In en, this message translates to:
  /// **'Erase and start over'**
  String get eraseAndStartOver;

  /// No description provided for @deviceRemovedTitle.
  ///
  /// In en, this message translates to:
  /// **'This device is signed out'**
  String get deviceRemovedTitle;

  /// No description provided for @deviceRemovedBody.
  ///
  /// In en, this message translates to:
  /// **'It was disconnected from your account on another of your devices. Chats here no longer update, messages and calls don\'t reach it. Sign out to erase this device\'s copy — your chats stay on your other devices.'**
  String get deviceRemovedBody;

  /// No description provided for @deviceRemovedAction.
  ///
  /// In en, this message translates to:
  /// **'Sign out'**
  String get deviceRemovedAction;

  /// No description provided for @eraseConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'All chats on this phone will be deleted. This can\'t be undone.'**
  String get eraseConfirmTitle;

  /// No description provided for @eraseConfirmAction.
  ///
  /// In en, this message translates to:
  /// **'Erase everything'**
  String get eraseConfirmAction;

  /// No description provided for @netConnected.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get netConnected;

  /// No description provided for @netConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting…'**
  String get netConnecting;

  /// No description provided for @netOffline.
  ///
  /// In en, this message translates to:
  /// **'Offline'**
  String get netOffline;

  /// No description provided for @reconnect.
  ///
  /// In en, this message translates to:
  /// **'Reconnect'**
  String get reconnect;

  /// No description provided for @connection.
  ///
  /// In en, this message translates to:
  /// **'Connection'**
  String get connection;

  /// No description provided for @navNewChatName.
  ///
  /// In en, this message translates to:
  /// **'Chat {id}'**
  String navNewChatName(String id);

  /// No description provided for @chatDraftPrefix.
  ///
  /// In en, this message translates to:
  /// **'Draft: '**
  String get chatDraftPrefix;

  /// No description provided for @phraseStrengthValue.
  ///
  /// In en, this message translates to:
  /// **'Very high'**
  String get phraseStrengthValue;

  /// No description provided for @photoCouldNotUse.
  ///
  /// In en, this message translates to:
  /// **'Couldn’t use this photo. Check access to Photos: phone Settings → Sinhron → Photos.'**
  String get photoCouldNotUse;

  /// No description provided for @backupSearching.
  ///
  /// In en, this message translates to:
  /// **'Looking for a backup…'**
  String get backupSearching;

  /// No description provided for @errRecordingFailed.
  ///
  /// In en, this message translates to:
  /// **'The recording didn’t work — try again'**
  String get errRecordingFailed;

  /// No description provided for @linkCouldNotOpen.
  ///
  /// In en, this message translates to:
  /// **'Couldn’t open the link'**
  String get linkCouldNotOpen;

  /// No description provided for @newChatPlaceholder.
  ///
  /// In en, this message translates to:
  /// **'New chat'**
  String get newChatPlaceholder;

  /// No description provided for @newGroupPlaceholder.
  ///
  /// In en, this message translates to:
  /// **'New group'**
  String get newGroupPlaceholder;

  /// No description provided for @memberUnnamed.
  ///
  /// In en, this message translates to:
  /// **'Member'**
  String get memberUnnamed;

  /// No description provided for @appLockOffNoPasscode.
  ///
  /// In en, this message translates to:
  /// **'App Lock is off: this phone has no passcode or Face ID any more. Turn it on again in Settings → App lock.'**
  String get appLockOffNoPasscode;

  /// No description provided for @unlockFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn’t open — not because of the words. Try again in a minute.'**
  String get unlockFailed;

  /// No description provided for @navErrKeyAlreadyInChat.
  ///
  /// In en, this message translates to:
  /// **'That address is already in the chat — probably your own. Paste the other person’s address, not yours.'**
  String get navErrKeyAlreadyInChat;

  /// No description provided for @navErrNoKeyPackage.
  ///
  /// In en, this message translates to:
  /// **'Can’t invite them yet: their phone hasn’t finished setting up. Ask them to open Sinhron and wait until it has loaded, then try again.'**
  String get navErrNoKeyPackage;

  /// No description provided for @navErrRateLimited.
  ///
  /// In en, this message translates to:
  /// **'Too many requests to the server. Wait a minute and try again.'**
  String get navErrRateLimited;

  /// No description provided for @navErrServerUnreachable.
  ///
  /// In en, this message translates to:
  /// **'Could not reach the server. Check your internet connection — Sinhron reconnects by itself.'**
  String get navErrServerUnreachable;

  /// No description provided for @navErrBadKeyFormat.
  ///
  /// In en, this message translates to:
  /// **'An address is exactly 64 characters: digits and the letters a–f. Check that you copied all of it.'**
  String get navErrBadKeyFormat;

  /// No description provided for @netGroupDefaultName.
  ///
  /// In en, this message translates to:
  /// **'Group {id}'**
  String netGroupDefaultName(String id);

  /// No description provided for @netAddedToChat.
  ///
  /// In en, this message translates to:
  /// **'You were added to this chat'**
  String get netAddedToChat;

  /// No description provided for @netUnsupportedMessage.
  ///
  /// In en, this message translates to:
  /// **'Unsupported message — update Sinhron to view it'**
  String get netUnsupportedMessage;

  /// No description provided for @chatsEncryptedStarted.
  ///
  /// In en, this message translates to:
  /// **'Encrypted chat started'**
  String get chatsEncryptedStarted;

  /// No description provided for @callKitPeerName.
  ///
  /// In en, this message translates to:
  /// **'Sinhron call'**
  String get callKitPeerName;

  /// Outgoing call failed: mic
  ///
  /// In en, this message translates to:
  /// **'No access to the microphone. Allow it in Settings → Sinhron → Microphone.'**
  String get callErrMic;

  /// Outgoing call failed: camera
  ///
  /// In en, this message translates to:
  /// **'No access to the camera. Allow it in Settings → Sinhron → Camera.'**
  String get callErrCamera;

  /// Outgoing call failed: failed
  ///
  /// In en, this message translates to:
  /// **'Couldn’t start the call. Check your connection and try again.'**
  String get callErrFailed;

  /// No description provided for @callsMissed.
  ///
  /// In en, this message translates to:
  /// **'Missed'**
  String get callsMissed;

  /// No description provided for @callsEarlier.
  ///
  /// In en, this message translates to:
  /// **'Earlier'**
  String get callsEarlier;

  /// No description provided for @callsAudio.
  ///
  /// In en, this message translates to:
  /// **'audio'**
  String get callsAudio;

  /// No description provided for @callsVideo.
  ///
  /// In en, this message translates to:
  /// **'video'**
  String get callsVideo;

  /// No description provided for @callsMinutes.
  ///
  /// In en, this message translates to:
  /// **'{n} min'**
  String callsMinutes(int n);

  /// No description provided for @callsNoAnswer.
  ///
  /// In en, this message translates to:
  /// **'No answer'**
  String get callsNoAnswer;

  /// No description provided for @callsDeclined.
  ///
  /// In en, this message translates to:
  /// **'Declined'**
  String get callsDeclined;

  /// No description provided for @callsEmpty.
  ///
  /// In en, this message translates to:
  /// **'No calls yet. Start one from a chat — the phone button at the top.'**
  String get callsEmpty;

  /// No description provided for @callIncomingVideo.
  ///
  /// In en, this message translates to:
  /// **'incoming video call'**
  String get callIncomingVideo;

  /// No description provided for @callIncomingAudio.
  ///
  /// In en, this message translates to:
  /// **'incoming Sinhron call'**
  String get callIncomingAudio;

  /// Outgoing call, still ringing on the other side
  ///
  /// In en, this message translates to:
  /// **'Calling…'**
  String get callCalling;

  /// No description provided for @callRinging.
  ///
  /// In en, this message translates to:
  /// **'Ringing…'**
  String get callRinging;

  /// Group call going on in a chat
  ///
  /// In en, this message translates to:
  /// **'Call in progress'**
  String get callOngoing;

  /// Group call going on in a chat
  ///
  /// In en, this message translates to:
  /// **'Video call in progress'**
  String get callOngoingVideo;

  /// Group call going on in a chat
  ///
  /// In en, this message translates to:
  /// **'Join'**
  String get callJoin;

  /// Group call going on in a chat
  ///
  /// In en, this message translates to:
  /// **'Couldn’t join — the call has ended.'**
  String get callJoinFailed;

  /// Group call: nobody else has joined yet
  ///
  /// In en, this message translates to:
  /// **'Waiting for others to join…'**
  String get callWaitingForPeople;

  /// No description provided for @callDecline.
  ///
  /// In en, this message translates to:
  /// **'Decline'**
  String get callDecline;

  /// No description provided for @callAccept.
  ///
  /// In en, this message translates to:
  /// **'Accept'**
  String get callAccept;

  /// No description provided for @callUnmute.
  ///
  /// In en, this message translates to:
  /// **'Unmute'**
  String get callUnmute;

  /// Call: switch front/back camera
  ///
  /// In en, this message translates to:
  /// **'Flip'**
  String get callFlipCamera;

  /// No description provided for @callMute.
  ///
  /// In en, this message translates to:
  /// **'Mute'**
  String get callMute;

  /// No description provided for @callSpeaker.
  ///
  /// In en, this message translates to:
  /// **'Speaker'**
  String get callSpeaker;

  /// No description provided for @callEnd.
  ///
  /// In en, this message translates to:
  /// **'End'**
  String get callEnd;

  /// No description provided for @callEnded.
  ///
  /// In en, this message translates to:
  /// **'Call ended · {duration}'**
  String callEnded(String duration);

  /// No description provided for @callReconnecting.
  ///
  /// In en, this message translates to:
  /// **'Reconnecting…'**
  String get callReconnecting;

  /// No description provided for @callLinkQuality.
  ///
  /// In en, this message translates to:
  /// **'Connection quality'**
  String get callLinkQuality;

  /// No description provided for @callWeakLink.
  ///
  /// In en, this message translates to:
  /// **'Weak connection'**
  String get callWeakLink;

  /// No description provided for @callWeakLinkPeer.
  ///
  /// In en, this message translates to:
  /// **'Weak connection on the other side'**
  String get callWeakLinkPeer;

  /// No description provided for @callAutoAudioOnly.
  ///
  /// In en, this message translates to:
  /// **'Weak connection — camera off to keep the voice'**
  String get callAutoAudioOnly;

  /// No description provided for @callBarTapToReturn.
  ///
  /// In en, this message translates to:
  /// **'Tap to return'**
  String get callBarTapToReturn;

  /// No description provided for @contactsFavourites.
  ///
  /// In en, this message translates to:
  /// **'Favourites'**
  String get contactsFavourites;

  /// No description provided for @contactsVerified.
  ///
  /// In en, this message translates to:
  /// **'Verified'**
  String get contactsVerified;

  /// No description provided for @contactsInvite.
  ///
  /// In en, this message translates to:
  /// **'Invite friends'**
  String get contactsInvite;

  /// No description provided for @contactsInviteHint.
  ///
  /// In en, this message translates to:
  /// **'Send a link — one tap adds you to their contacts'**
  String get contactsInviteHint;

  /// No description provided for @contactAdd.
  ///
  /// In en, this message translates to:
  /// **'Add to contacts'**
  String get contactAdd;

  /// No description provided for @contactEditName.
  ///
  /// In en, this message translates to:
  /// **'Edit name'**
  String get contactEditName;

  /// No description provided for @contactNameOnlyYou.
  ///
  /// In en, this message translates to:
  /// **'Only you see this'**
  String get contactNameOnlyYou;

  /// No description provided for @contactNameRestore.
  ///
  /// In en, this message translates to:
  /// **'Restore “{name}”'**
  String contactNameRestore(String name);

  /// No description provided for @contactRemove.
  ///
  /// In en, this message translates to:
  /// **'Remove from contacts'**
  String get contactRemove;

  /// No description provided for @contactRemoveConfirm.
  ///
  /// In en, this message translates to:
  /// **'Remove {name} from contacts? The chat stays.'**
  String contactRemoveConfirm(String name);

  /// No description provided for @contactFavouriteAdd.
  ///
  /// In en, this message translates to:
  /// **'Add to favourites'**
  String get contactFavouriteAdd;

  /// No description provided for @contactFavouriteRemove.
  ///
  /// In en, this message translates to:
  /// **'Remove from favourites'**
  String get contactFavouriteRemove;

  /// No description provided for @contactKey.
  ///
  /// In en, this message translates to:
  /// **'Key'**
  String get contactKey;

  /// No description provided for @profileAboutHint.
  ///
  /// In en, this message translates to:
  /// **'The people you chat with see it in your profile'**
  String get profileAboutHint;

  /// No description provided for @contactsAllCount.
  ///
  /// In en, this message translates to:
  /// **'All contacts · {n}'**
  String contactsAllCount(int n);

  /// No description provided for @contactIdentityVerified.
  ///
  /// In en, this message translates to:
  /// **'Checked by you'**
  String get contactIdentityVerified;

  /// No description provided for @contactAbout.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get contactAbout;

  /// No description provided for @contactIdentity.
  ///
  /// In en, this message translates to:
  /// **'Checking'**
  String get contactIdentity;

  /// No description provided for @contactMessage.
  ///
  /// In en, this message translates to:
  /// **'Message'**
  String get contactMessage;

  /// No description provided for @contactMediaLinksDocs.
  ///
  /// In en, this message translates to:
  /// **'Media, links and docs'**
  String get contactMediaLinksDocs;

  /// No description provided for @contactGroupsInCommon.
  ///
  /// In en, this message translates to:
  /// **'{n, plural, =1{1 group in common} other{{n} groups in common}}'**
  String contactGroupsInCommon(int n);

  /// No description provided for @contactGroupMembers.
  ///
  /// In en, this message translates to:
  /// **'{n, plural, =1{1 member} other{{n} members}}'**
  String contactGroupMembers(int n);

  /// No description provided for @newGroupPickOne.
  ///
  /// In en, this message translates to:
  /// **'Pick at least one contact'**
  String get newGroupPickOne;

  /// No description provided for @newGroupNext.
  ///
  /// In en, this message translates to:
  /// **'Next · {n} selected'**
  String newGroupNext(int n);

  /// No description provided for @newGroupAllContacts.
  ///
  /// In en, this message translates to:
  /// **'All contacts'**
  String get newGroupAllContacts;

  /// No description provided for @newGroupCreate.
  ///
  /// In en, this message translates to:
  /// **'Create group'**
  String get newGroupCreate;

  /// No description provided for @newGroupName.
  ///
  /// In en, this message translates to:
  /// **'Group name'**
  String get newGroupName;

  /// No description provided for @newGroupMembersCount.
  ///
  /// In en, this message translates to:
  /// **'Members · {n}'**
  String newGroupMembersCount(int n);

  /// No description provided for @groupInfoAdmin.
  ///
  /// In en, this message translates to:
  /// **'Admin'**
  String get groupInfoAdmin;

  /// No description provided for @newGroupFooter.
  ///
  /// In en, this message translates to:
  /// **'Members get the group straight from your phone, encrypted. The server only passes it along — it can’t see who’s in it or what’s said.'**
  String get newGroupFooter;

  /// No description provided for @newGroupAddCta.
  ///
  /// In en, this message translates to:
  /// **'Add · {n} selected'**
  String newGroupAddCta(int n);

  /// No description provided for @newGroupNoContacts.
  ///
  /// In en, this message translates to:
  /// **'No one to add yet. Start a personal chat with someone first — then you can put them in a group.'**
  String get newGroupNoContacts;

  /// No description provided for @newGroupNoOneToAdd.
  ///
  /// In en, this message translates to:
  /// **'Everyone you chat with is already in this group.'**
  String get newGroupNoOneToAdd;

  /// No description provided for @newGroupCreating.
  ///
  /// In en, this message translates to:
  /// **'Creating the group…'**
  String get newGroupCreating;

  /// No description provided for @groupInfoMembers.
  ///
  /// In en, this message translates to:
  /// **'Members'**
  String get groupInfoMembers;

  /// No description provided for @groupInfoMediaFiles.
  ///
  /// In en, this message translates to:
  /// **'Media & files'**
  String get groupInfoMediaFiles;

  /// No description provided for @groupInfoAddMember.
  ///
  /// In en, this message translates to:
  /// **'Add member'**
  String get groupInfoAddMember;

  /// No description provided for @groupInfoMemberYou.
  ///
  /// In en, this message translates to:
  /// **'{name} (you)'**
  String groupInfoMemberYou(String name);

  /// No description provided for @blockedTitle.
  ///
  /// In en, this message translates to:
  /// **'Blocked'**
  String get blockedTitle;

  /// No description provided for @blockedCount.
  ///
  /// In en, this message translates to:
  /// **'{n} blocked'**
  String blockedCount(int n);

  /// No description provided for @blockedUnblock.
  ///
  /// In en, this message translates to:
  /// **'Unblock'**
  String get blockedUnblock;

  /// No description provided for @blockedWhatItDoes.
  ///
  /// In en, this message translates to:
  /// **'What blocking does'**
  String get blockedWhatItDoes;

  /// No description provided for @blockedNoPresence.
  ///
  /// In en, this message translates to:
  /// **'A blocked person never sees when you’re online.'**
  String get blockedNoPresence;

  /// No description provided for @blockedMessagesDiscarded.
  ///
  /// In en, this message translates to:
  /// **'Their messages and reactions are dropped on this device — they aren’t told.'**
  String get blockedMessagesDiscarded;

  /// No description provided for @blockedCallsRejected.
  ///
  /// In en, this message translates to:
  /// **'Calls in your personal chat with them are declined without ringing.'**
  String get blockedCallsRejected;

  /// No description provided for @blockedNoGroups.
  ///
  /// In en, this message translates to:
  /// **'In shared groups their messages are hidden from you; the group itself is unchanged.'**
  String get blockedNoGroups;

  /// No description provided for @blockedLocalFooter.
  ///
  /// In en, this message translates to:
  /// **'The block list stays on this phone only. Your server never learns who you blocked.'**
  String get blockedLocalFooter;

  /// No description provided for @blockedEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'Nobody blocked'**
  String get blockedEmptyTitle;

  /// No description provided for @blockedEmptyHint.
  ///
  /// In en, this message translates to:
  /// **'Block someone from the Info screen of a chat. Blocking works on this device only.'**
  String get blockedEmptyHint;

  /// No description provided for @sharedMediaTitle.
  ///
  /// In en, this message translates to:
  /// **'Shared media'**
  String get sharedMediaTitle;

  /// No description provided for @sharedMediaDocuments.
  ///
  /// In en, this message translates to:
  /// **'Documents'**
  String get sharedMediaDocuments;

  /// No description provided for @sharedMediaVoice.
  ///
  /// In en, this message translates to:
  /// **'Voice'**
  String get sharedMediaVoice;

  /// No description provided for @inviteLandingTitle.
  ///
  /// In en, this message translates to:
  /// **'You’ve been invited to join a Sinhron server'**
  String get inviteLandingTitle;

  /// No description provided for @inviteLandingBody.
  ///
  /// In en, this message translates to:
  /// **'Sinhron is a private messenger that runs on a server you trust. Below is the server you’ll be joining — and who invited you.'**
  String get inviteLandingBody;

  /// No description provided for @inviteStepName.
  ///
  /// In en, this message translates to:
  /// **'Pick a display name'**
  String get inviteStepName;

  /// No description provided for @inviteStepNameBody.
  ///
  /// In en, this message translates to:
  /// **'No email, no phone, no password'**
  String get inviteStepNameBody;

  /// No description provided for @inviteStepPhrase.
  ///
  /// In en, this message translates to:
  /// **'Write down your 24 secret words'**
  String get inviteStepPhrase;

  /// No description provided for @inviteStepPhraseBody.
  ///
  /// In en, this message translates to:
  /// **'The only way to restore your account later'**
  String get inviteStepPhraseBody;

  /// No description provided for @inviteStepDone.
  ///
  /// In en, this message translates to:
  /// **'You’re in'**
  String get inviteStepDone;

  /// No description provided for @inviteStepDoneBody.
  ///
  /// In en, this message translates to:
  /// **'{name} will be the first contact in your list'**
  String inviteStepDoneBody(String name);

  /// No description provided for @inviteAccept.
  ///
  /// In en, this message translates to:
  /// **'Accept & set up'**
  String get inviteAccept;

  /// No description provided for @inviteHaveAccount.
  ///
  /// In en, this message translates to:
  /// **'I already have an account'**
  String get inviteHaveAccount;

  /// No description provided for @inviteEyebrow.
  ///
  /// In en, this message translates to:
  /// **'INVITE LINK'**
  String get inviteEyebrow;

  /// No description provided for @inviteReachable.
  ///
  /// In en, this message translates to:
  /// **'Reachable · {ms} ms'**
  String inviteReachable(int ms);

  /// No description provided for @inviteInvitedBy.
  ///
  /// In en, this message translates to:
  /// **'Invited by'**
  String get inviteInvitedBy;

  /// No description provided for @inviteExpiresInHours.
  ///
  /// In en, this message translates to:
  /// **'Expires in {n}h'**
  String inviteExpiresInHours(int n);

  /// No description provided for @inviteNextSteps.
  ///
  /// In en, this message translates to:
  /// **'NEXT STEPS'**
  String get inviteNextSteps;

  /// No description provided for @legalYourIdentity.
  ///
  /// In en, this message translates to:
  /// **'Your account'**
  String get legalYourIdentity;

  /// No description provided for @safetyNumberTitle.
  ///
  /// In en, this message translates to:
  /// **'Check it’s really them'**
  String get safetyNumberTitle;

  /// No description provided for @serverStatus.
  ///
  /// In en, this message translates to:
  /// **'Status'**
  String get serverStatus;

  /// No description provided for @serverProtocol.
  ///
  /// In en, this message translates to:
  /// **'Protocol'**
  String get serverProtocol;

  /// No description provided for @serverTrustTitle.
  ///
  /// In en, this message translates to:
  /// **'TRUST'**
  String get serverTrustTitle;

  /// No description provided for @serverSees.
  ///
  /// In en, this message translates to:
  /// **'What this server sees'**
  String get serverSees;

  /// No description provided for @serverCantSee.
  ///
  /// In en, this message translates to:
  /// **'What it can\'t see'**
  String get serverCantSee;

  /// No description provided for @serverSeesTiming.
  ///
  /// In en, this message translates to:
  /// **'Delivery timing'**
  String get serverSeesTiming;

  /// No description provided for @serverSeesOnline.
  ///
  /// In en, this message translates to:
  /// **'When you’re online'**
  String get serverSeesOnline;

  /// No description provided for @serverSeesPush.
  ///
  /// In en, this message translates to:
  /// **'Notification address'**
  String get serverSeesPush;

  /// No description provided for @serverSeesQuota.
  ///
  /// In en, this message translates to:
  /// **'How much space you use'**
  String get serverSeesQuota;

  /// No description provided for @serverHiddenContent.
  ///
  /// In en, this message translates to:
  /// **'Message text'**
  String get serverHiddenContent;

  /// No description provided for @serverHiddenFiles.
  ///
  /// In en, this message translates to:
  /// **'Files'**
  String get serverHiddenFiles;

  /// No description provided for @serverHiddenContacts.
  ///
  /// In en, this message translates to:
  /// **'Who you talk to'**
  String get serverHiddenContacts;

  /// No description provided for @serverTrustFooter.
  ///
  /// In en, this message translates to:
  /// **'That’s how the encryption itself works — the server can’t switch it off, even if it wanted to.'**
  String get serverTrustFooter;

  /// No description provided for @devicesCurrent.
  ///
  /// In en, this message translates to:
  /// **'Current device'**
  String get devicesCurrent;

  /// No description provided for @devicesOther.
  ///
  /// In en, this message translates to:
  /// **'Other devices'**
  String get devicesOther;

  /// No description provided for @devicesOtherFooter.
  ///
  /// In en, this message translates to:
  /// **'Your devices share your encrypted chats. Remove one and it can no longer read anything new — from the very next message.'**
  String get devicesOtherFooter;

  /// No description provided for @devicesOnlyOne.
  ///
  /// In en, this message translates to:
  /// **'This is your only device. To use Sinhron on another one, tap “Link a new device” above.'**
  String get devicesOnlyOne;

  /// No description provided for @devicesRemoveAll.
  ///
  /// In en, this message translates to:
  /// **'Remove all other devices ({n})'**
  String devicesRemoveAll(int n);

  /// No description provided for @devicesLinkedCount.
  ///
  /// In en, this message translates to:
  /// **'{n, plural, =1{device linked} other{devices linked}}'**
  String devicesLinkedCount(int n);

  /// No description provided for @devicesHeroBody.
  ///
  /// In en, this message translates to:
  /// **'Use Sinhron on all your devices at once — the chats are the same everywhere and never stored unencrypted.'**
  String get devicesHeroBody;

  /// No description provided for @devicesLinkNew.
  ///
  /// In en, this message translates to:
  /// **'Link a new device'**
  String get devicesLinkNew;

  /// No description provided for @devicesModelLinked.
  ///
  /// In en, this message translates to:
  /// **'{model} · linked {date}'**
  String devicesModelLinked(String model, String date);

  /// No description provided for @devicesLastActive.
  ///
  /// In en, this message translates to:
  /// **'Last active {time}'**
  String devicesLastActive(String time);

  /// No description provided for @devicesRevoke.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get devicesRevoke;

  /// No description provided for @done.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get done;

  /// No description provided for @storageVideos.
  ///
  /// In en, this message translates to:
  /// **'Videos'**
  String get storageVideos;

  /// No description provided for @storageVoice.
  ///
  /// In en, this message translates to:
  /// **'Voice messages'**
  String get storageVoice;

  /// No description provided for @storageByType.
  ///
  /// In en, this message translates to:
  /// **'By type'**
  String get storageByType;

  /// No description provided for @storageTopChats.
  ///
  /// In en, this message translates to:
  /// **'Top chats'**
  String get storageTopChats;

  /// No description provided for @storageManage.
  ///
  /// In en, this message translates to:
  /// **'Manage'**
  String get storageManage;

  /// No description provided for @storageMbUnit.
  ///
  /// In en, this message translates to:
  /// **'MB'**
  String get storageMbUnit;

  /// No description provided for @phraseStatusTitle.
  ///
  /// In en, this message translates to:
  /// **'Secret words'**
  String get phraseStatusTitle;

  /// No description provided for @phraseStatusStrength.
  ///
  /// In en, this message translates to:
  /// **'Strength'**
  String get phraseStatusStrength;

  /// No description provided for @phraseStatusActions.
  ///
  /// In en, this message translates to:
  /// **'Actions'**
  String get phraseStatusActions;

  /// No description provided for @phraseStatusActionsFooter.
  ///
  /// In en, this message translates to:
  /// **'The phone doesn’t keep the words once they’re saved — only what it needs to sign you in — so they can’t be shown again. Not sure you have the right words? Check them.'**
  String get phraseStatusActionsFooter;

  /// No description provided for @phraseStatusReverify.
  ///
  /// In en, this message translates to:
  /// **'Check the words'**
  String get phraseStatusReverify;

  /// No description provided for @phraseStatusTip.
  ///
  /// In en, this message translates to:
  /// **'Keep the 24 words in two places — for example, in iCloud Keychain or the password manager, and on paper. They bring your whole account back — anyone who reads them can sign in as you on a new phone.'**
  String get phraseStatusTip;

  /// No description provided for @showQrTitleMy.
  ///
  /// In en, this message translates to:
  /// **'My QR code'**
  String get showQrTitleMy;

  /// No description provided for @showQrTitleInvite.
  ///
  /// In en, this message translates to:
  /// **'Invite to Sinhron'**
  String get showQrTitleInvite;

  /// No description provided for @showQrFooterMy.
  ///
  /// In en, this message translates to:
  /// **'Anyone who scans this QR can ask {username} for a chat. It’s not a password or a secret — they can make sure it’s you later with the check number.'**
  String showQrFooterMy(String username);

  /// No description provided for @showQrFooterInvite.
  ///
  /// In en, this message translates to:
  /// **'Show this code to a friend, or send the link below. Anyone who scans it can request a chat with you and join {server}.'**
  String showQrFooterInvite(String server);

  /// No description provided for @showQrOnServer.
  ///
  /// In en, this message translates to:
  /// **'on {server}'**
  String showQrOnServer(String server);

  /// No description provided for @showQrCopyLink.
  ///
  /// In en, this message translates to:
  /// **'Copy link'**
  String get showQrCopyLink;

  /// My QR code: copy my identity key
  ///
  /// In en, this message translates to:
  /// **'Copy address'**
  String get showQrCopyKey;

  /// My QR code footer: what the QR holds
  ///
  /// In en, this message translates to:
  /// **'Anyone who scans this code can message you. It holds only your address and server — not a password, nothing secret. The other person can make sure it’s really you in the chat — “Check it’s really them”.'**
  String get showQrFooterReal;

  /// Text shared from My QR code
  ///
  /// In en, this message translates to:
  /// **'Message me on Sinhron — my address: {key}\nServer: {server}'**
  String showQrShareText(String key, String server);

  /// Toast after copying my key
  ///
  /// In en, this message translates to:
  /// **'Address copied'**
  String get showQrKeyCopied;

  /// Scanned QR is not a Sinhron contact
  ///
  /// In en, this message translates to:
  /// **'This QR code isn’t a Sinhron contact.'**
  String get scanContactNotSinhron;

  /// Scanned contact is on another server
  ///
  /// In en, this message translates to:
  /// **'This person is on {server}. Chats only work between people on the same server.'**
  String scanContactOtherServer(String server);

  /// Scanned my own QR
  ///
  /// In en, this message translates to:
  /// **'That’s your own code.'**
  String get scanContactSelf;

  /// No description provided for @showQrSaveImage.
  ///
  /// In en, this message translates to:
  /// **'Save image'**
  String get showQrSaveImage;

  /// No description provided for @signOutTitle.
  ///
  /// In en, this message translates to:
  /// **'Sign out'**
  String get signOutTitle;

  /// No description provided for @signOutHeading.
  ///
  /// In en, this message translates to:
  /// **'Sign out from this device'**
  String get signOutHeading;

  /// No description provided for @signOutReminderTitle.
  ///
  /// In en, this message translates to:
  /// **'Got your secret words handy?'**
  String get signOutReminderTitle;

  /// No description provided for @signOutReminderBody.
  ///
  /// In en, this message translates to:
  /// **'Without your 24 words, this device is gone for good. Your other devices keep working — but you won\'t get back on this one.'**
  String get signOutReminderBody;

  /// No description provided for @signOutWhatHappens.
  ///
  /// In en, this message translates to:
  /// **'WHAT HAPPENS'**
  String get signOutWhatHappens;

  /// No description provided for @signOutRowSignedOut.
  ///
  /// In en, this message translates to:
  /// **'This device is signed out and can no longer read your chats.'**
  String get signOutRowSignedOut;

  /// No description provided for @signOutRowOtherDevices.
  ///
  /// In en, this message translates to:
  /// **'{n, plural, =1{Your other device keeps working — it has its own keys.} other{Your other {n} devices keep working — they have their own keys.}}'**
  String signOutRowOtherDevices(int n);

  /// No description provided for @signOutRowWipe.
  ///
  /// In en, this message translates to:
  /// **'Chats and keys on this device are erased.'**
  String get signOutRowWipe;

  /// No description provided for @signOutRowComeBack.
  ///
  /// In en, this message translates to:
  /// **'To come back, sign in again with your 24 secret words.'**
  String get signOutRowComeBack;

  /// No description provided for @deleteAccountTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete account'**
  String get deleteAccountTitle;

  /// No description provided for @profileEditServerCopied.
  ///
  /// In en, this message translates to:
  /// **'Server copied'**
  String get profileEditServerCopied;

  /// No description provided for @profileEditKeyCopied.
  ///
  /// In en, this message translates to:
  /// **'Address copied'**
  String get profileEditKeyCopied;

  /// No description provided for @profileEditNoPhoneNote.
  ///
  /// In en, this message translates to:
  /// **'No phone number, no login: people reach you by your address or QR code. Only the people you chat with see your name and photo — they travel encrypted. About stays on this phone only.'**
  String get profileEditNoPhoneNote;

  /// No description provided for @profileEditIdentityFooter.
  ///
  /// In en, this message translates to:
  /// **'Send your address or show your QR code and people can message you. With people who matter, check it’s really you two talking: Info → “Check it’s really them”.'**
  String get profileEditIdentityFooter;

  /// No description provided for @profileEditCopyKey.
  ///
  /// In en, this message translates to:
  /// **'Copy address'**
  String get profileEditCopyKey;

  /// No description provided for @profileEditNotReady.
  ///
  /// In en, this message translates to:
  /// **'Not ready'**
  String get profileEditNotReady;

  /// No description provided for @profileEditTapToCopy.
  ///
  /// In en, this message translates to:
  /// **'Tap to copy'**
  String get profileEditTapToCopy;

  /// No description provided for @profileEditShowQr.
  ///
  /// In en, this message translates to:
  /// **'Show my QR code'**
  String get profileEditShowQr;

  /// No description provided for @profileEditShareHandle.
  ///
  /// In en, this message translates to:
  /// **'Share so people can message me'**
  String get profileEditShareHandle;

  /// No description provided for @profileEditJoined.
  ///
  /// In en, this message translates to:
  /// **'On Sinhron since'**
  String get profileEditJoined;

  /// No description provided for @profileEditWhoSees.
  ///
  /// In en, this message translates to:
  /// **'Who can see your profile'**
  String get profileEditWhoSees;

  /// No description provided for @profileEditSignOut.
  ///
  /// In en, this message translates to:
  /// **'Sign out on this device'**
  String get profileEditSignOut;

  /// No description provided for @profileEditAccountFooter.
  ///
  /// In en, this message translates to:
  /// **'Sign out only clears this device — your other linked devices keep working. Deleting the account is immediate and can’t be undone.'**
  String get profileEditAccountFooter;

  /// No description provided for @profileEditTitle.
  ///
  /// In en, this message translates to:
  /// **'Edit profile'**
  String get profileEditTitle;

  /// No description provided for @profileEditChangePhoto.
  ///
  /// In en, this message translates to:
  /// **'Change photo'**
  String get profileEditChangePhoto;

  /// No description provided for @profileEditHandle.
  ///
  /// In en, this message translates to:
  /// **'Server'**
  String get profileEditHandle;

  /// No description provided for @profileEditStrength.
  ///
  /// In en, this message translates to:
  /// **'Protection'**
  String get profileEditStrength;

  /// No description provided for @devicesHowToLink.
  ///
  /// In en, this message translates to:
  /// **'Or, on the new device, tap “Sign in with secret words” and enter your 24 words. It joins your chats once this phone is online.'**
  String get devicesHowToLink;

  /// No description provided for @devicesUnnamed.
  ///
  /// In en, this message translates to:
  /// **'Another device'**
  String get devicesUnnamed;

  /// No description provided for @devicesFirstDevice.
  ///
  /// In en, this message translates to:
  /// **'first device'**
  String get devicesFirstDevice;

  /// No description provided for @devicesLinkedOn.
  ///
  /// In en, this message translates to:
  /// **'linked {date}'**
  String devicesLinkedOn(String date);

  /// No description provided for @devicesRevokeTitle.
  ///
  /// In en, this message translates to:
  /// **'Remove this device? It stops receiving your messages from the very next one.'**
  String get devicesRevokeTitle;

  /// No description provided for @devicesRevokeAction.
  ///
  /// In en, this message translates to:
  /// **'Remove device'**
  String get devicesRevokeAction;

  /// No description provided for @devicesLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Can\'t load your devices — no connection to the server.'**
  String get devicesLoadFailed;

  /// No description provided for @devicesRevokeFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t remove the device. Try again when you\'re online.'**
  String get devicesRevokeFailed;

  /// No description provided for @restoreTitle.
  ///
  /// In en, this message translates to:
  /// **'Sign in to your account'**
  String get restoreTitle;

  /// No description provided for @restoreBody.
  ///
  /// In en, this message translates to:
  /// **'Enter your 24 secret words. This phone becomes one more of your devices: your chats arrive here while your other device is online. Earlier messages stay on that device.'**
  String get restoreBody;

  /// No description provided for @restoreAction.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get restoreAction;

  /// No description provided for @pairTitle.
  ///
  /// In en, this message translates to:
  /// **'Link to your account'**
  String get pairTitle;

  /// No description provided for @pairBody.
  ///
  /// In en, this message translates to:
  /// **'On the device you already use, open Settings → Devices → “Link a new device” and scan this code.'**
  String get pairBody;

  /// No description provided for @pairWaiting.
  ///
  /// In en, this message translates to:
  /// **'Waiting for your other device…'**
  String get pairWaiting;

  /// No description provided for @pairCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy code'**
  String get pairCopy;

  /// No description provided for @pairCopied.
  ///
  /// In en, this message translates to:
  /// **'Copied — paste it on your other device.'**
  String get pairCopied;

  /// No description provided for @pairFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t link. Check the connection and try again.'**
  String get pairFailed;

  /// No description provided for @pairUseWords.
  ///
  /// In en, this message translates to:
  /// **'Enter the 24 words instead'**
  String get pairUseWords;

  /// No description provided for @pairCodeUsed.
  ///
  /// In en, this message translates to:
  /// **'Another device took this code. Here is a new one — show it only to your own device.'**
  String get pairCodeUsed;

  /// New device, before signing in by QR: whose account answered (start of its key)
  ///
  /// In en, this message translates to:
  /// **'Sign in to the account with address {address}? Check that your other phone shows the same address in its profile. If it doesn’t, tap Cancel.'**
  String pairConfirm(String address);

  /// No description provided for @pairConfirmAction.
  ///
  /// In en, this message translates to:
  /// **'Sign in'**
  String get pairConfirmAction;

  /// No description provided for @restoreUseQr.
  ///
  /// In en, this message translates to:
  /// **'Your other device is nearby? Link with a QR code'**
  String get restoreUseQr;

  /// No description provided for @addDeviceBody.
  ///
  /// In en, this message translates to:
  /// **'On the new device choose “Link a device” — it shows a QR code. Scan it here.'**
  String get addDeviceBody;

  /// No description provided for @addDeviceScan.
  ///
  /// In en, this message translates to:
  /// **'Scan QR code'**
  String get addDeviceScan;

  /// No description provided for @addDevicePasteHint.
  ///
  /// In en, this message translates to:
  /// **'…or paste the code'**
  String get addDevicePasteHint;

  /// No description provided for @addDeviceAction.
  ///
  /// In en, this message translates to:
  /// **'Add device'**
  String get addDeviceAction;

  /// No description provided for @addDeviceNotACode.
  ///
  /// In en, this message translates to:
  /// **'That’s not a Sinhron link code.'**
  String get addDeviceNotACode;

  /// Confirm linking a device; the address is the start of my key
  ///
  /// In en, this message translates to:
  /// **'Give this device access to your account? It will receive all your new messages. The new device will ask you to check your address: {address}.'**
  String addDeviceConfirm(String address);

  /// No description provided for @addDeviceConfirmAction.
  ///
  /// In en, this message translates to:
  /// **'Give access'**
  String get addDeviceConfirmAction;

  /// No description provided for @addDeviceDone.
  ///
  /// In en, this message translates to:
  /// **'Done — the new device is signing in. It joins your chats within a minute.'**
  String get addDeviceDone;

  /// No description provided for @addDeviceFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t send it. Check the connection and try again.'**
  String get addDeviceFailed;

  /// No description provided for @addDeviceCodeUsed.
  ///
  /// In en, this message translates to:
  /// **'This code was already used by another device. If that wasn\'t you, don\'t confirm anything.'**
  String get addDeviceCodeUsed;

  /// No description provided for @sealedSectionTitle.
  ///
  /// In en, this message translates to:
  /// **'Anonymous messages'**
  String get sealedSectionTitle;

  /// No description provided for @sealedResetAction.
  ///
  /// In en, this message translates to:
  /// **'Reset access for anonymous messages'**
  String get sealedResetAction;

  /// No description provided for @sealedResetFooter.
  ///
  /// In en, this message translates to:
  /// **'People you chat with send you messages without the server learning who sent them. If someone you no longer talk to shouldn’t be able to, reset the access — your current chats get the new one by themselves.'**
  String get sealedResetFooter;

  /// No description provided for @sealedResetConfirm.
  ///
  /// In en, this message translates to:
  /// **'Reset the access? Your chats get the new one by themselves; anyone else who had the old one can no longer message you anonymously.'**
  String get sealedResetConfirm;

  /// No description provided for @sealedResetDone.
  ///
  /// In en, this message translates to:
  /// **'Access reset'**
  String get sealedResetDone;

  /// No description provided for @devicesNotPrimary.
  ///
  /// In en, this message translates to:
  /// **'This device was added to your account later: adding or removing devices asks for your 24 secret words.'**
  String get devicesNotPrimary;

  /// No description provided for @phrasePromptTitle.
  ///
  /// In en, this message translates to:
  /// **'Enter your secret words'**
  String get phrasePromptTitle;

  /// No description provided for @phrasePromptBody.
  ///
  /// In en, this message translates to:
  /// **'This device was added to your account later. Enter your 24 secret words to go on — they’re used for this step only and aren’t stored.'**
  String get phrasePromptBody;

  /// No description provided for @phrasePromptAction.
  ///
  /// In en, this message translates to:
  /// **'Confirm'**
  String get phrasePromptAction;

  /// No description provided for @proxyTitle.
  ///
  /// In en, this message translates to:
  /// **'Proxy (Tor)'**
  String get proxyTitle;

  /// No description provided for @proxyBody.
  ///
  /// In en, this message translates to:
  /// **'For experts: all traffic to your server goes through a proxy (SOCKS5), so the server never learns this phone’s internet address (IP) — for example Tor via Orbot at 127.0.0.1:9050. Leave empty to connect directly. Calls don’t use it.'**
  String get proxyBody;

  /// No description provided for @proxySave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get proxySave;

  /// No description provided for @proxyInvalid.
  ///
  /// In en, this message translates to:
  /// **'Enter host:port, e.g. 127.0.0.1:9050.'**
  String get proxyInvalid;

  /// No description provided for @devicesSeenOn.
  ///
  /// In en, this message translates to:
  /// **'seen {date}'**
  String devicesSeenOn(String date);

  /// No description provided for @chatInfoTitle.
  ///
  /// In en, this message translates to:
  /// **'Info'**
  String get chatInfoTitle;

  /// No description provided for @chatInfoPersonal.
  ///
  /// In en, this message translates to:
  /// **'Personal chat · encrypted'**
  String get chatInfoPersonal;

  /// No description provided for @chatInfoUnnamed.
  ///
  /// In en, this message translates to:
  /// **'No name shared yet'**
  String get chatInfoUnnamed;

  /// No description provided for @chatInfoBlocked.
  ///
  /// In en, this message translates to:
  /// **'Blocked'**
  String get chatInfoBlocked;

  /// No description provided for @chatInfoBlock.
  ///
  /// In en, this message translates to:
  /// **'Block'**
  String get chatInfoBlock;

  /// No description provided for @chatInfoBlockConfirm.
  ///
  /// In en, this message translates to:
  /// **'Block {name}? Their messages and calls won’t reach this device. They aren’t told.'**
  String chatInfoBlockConfirm(String name);

  /// Group member sheet: open their profile (photo, bio).
  ///
  /// In en, this message translates to:
  /// **'Profile'**
  String get chatInfoMemberProfile;

  /// No description provided for @chatInfoVerify.
  ///
  /// In en, this message translates to:
  /// **'Check it’s really them'**
  String get chatInfoVerify;

  /// No description provided for @chatInfoMemberSafety.
  ///
  /// In en, this message translates to:
  /// **'Check it’s really {name}'**
  String chatInfoMemberSafety(String name);

  /// No description provided for @incomingCalls.
  ///
  /// In en, this message translates to:
  /// **'Incoming calls'**
  String get incomingCalls;

  /// No description provided for @incomingCallsFooter.
  ///
  /// In en, this message translates to:
  /// **'Off: incoming calls are declined without ringing. You can still call.'**
  String get incomingCallsFooter;

  /// No description provided for @blockedUnnamed.
  ///
  /// In en, this message translates to:
  /// **'Someone without a name'**
  String get blockedUnnamed;

  /// No description provided for @reorderPinned.
  ///
  /// In en, this message translates to:
  /// **'Reorder pinned chats'**
  String get reorderPinned;

  /// No description provided for @reorderPinnedTitle.
  ///
  /// In en, this message translates to:
  /// **'Pinned chats'**
  String get reorderPinnedTitle;

  /// No description provided for @reorderHint.
  ///
  /// In en, this message translates to:
  /// **'Hold a row and drag it to change the order.'**
  String get reorderHint;

  /// No description provided for @chatFolders.
  ///
  /// In en, this message translates to:
  /// **'Chat folders'**
  String get chatFolders;

  /// No description provided for @chatFoldersHint.
  ///
  /// In en, this message translates to:
  /// **'Folders are tabs above your chats. Hold a folder and drag it to change the order; switch it off to hide its tab.'**
  String get chatFoldersHint;

  /// No description provided for @myFolders.
  ///
  /// In en, this message translates to:
  /// **'My folders'**
  String get myFolders;

  /// No description provided for @createFolder.
  ///
  /// In en, this message translates to:
  /// **'Create a folder'**
  String get createFolder;

  /// No description provided for @suggestedFolders.
  ///
  /// In en, this message translates to:
  /// **'Suggested'**
  String get suggestedFolders;

  /// No description provided for @addFolder.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get addFolder;

  /// No description provided for @folderMuted.
  ///
  /// In en, this message translates to:
  /// **'Muted'**
  String get folderMuted;

  /// No description provided for @folderMutedHint.
  ///
  /// In en, this message translates to:
  /// **'Only chats with the sound off'**
  String get folderMutedHint;

  /// No description provided for @folderNotMuted.
  ///
  /// In en, this message translates to:
  /// **'Not muted'**
  String get folderNotMuted;

  /// No description provided for @folderNotMutedHint.
  ///
  /// In en, this message translates to:
  /// **'Chats that can notify you'**
  String get folderNotMutedHint;

  /// No description provided for @folderArchived.
  ///
  /// In en, this message translates to:
  /// **'Archived'**
  String get folderArchived;

  /// No description provided for @folderArchivedHint.
  ///
  /// In en, this message translates to:
  /// **'Chats you archived'**
  String get folderArchivedHint;

  /// No description provided for @folderChatCount.
  ///
  /// In en, this message translates to:
  /// **'{n, plural, =0{No chats} =1{1 chat} other{{n} chats}}'**
  String folderChatCount(int n);

  /// No description provided for @folderBuiltIn.
  ///
  /// In en, this message translates to:
  /// **'Standard'**
  String get folderBuiltIn;

  /// No description provided for @hideFolder.
  ///
  /// In en, this message translates to:
  /// **'Hide folder'**
  String get hideFolder;

  /// No description provided for @showFolderTab.
  ///
  /// In en, this message translates to:
  /// **'Show the “{name}” tab'**
  String showFolderTab(String name);

  /// No description provided for @editFolders.
  ///
  /// In en, this message translates to:
  /// **'Edit folders'**
  String get editFolders;

  /// No description provided for @folderChatTypes.
  ///
  /// In en, this message translates to:
  /// **'Chat types'**
  String get folderChatTypes;

  /// No description provided for @folderWhichChats.
  ///
  /// In en, this message translates to:
  /// **'Which chats'**
  String get folderWhichChats;

  /// No description provided for @onlyUnread.
  ///
  /// In en, this message translates to:
  /// **'Only unread'**
  String get onlyUnread;

  /// No description provided for @ruleShow.
  ///
  /// In en, this message translates to:
  /// **'Show'**
  String get ruleShow;

  /// No description provided for @ruleHide.
  ///
  /// In en, this message translates to:
  /// **'Hide'**
  String get ruleHide;

  /// No description provided for @ruleOnly.
  ///
  /// In en, this message translates to:
  /// **'Only these'**
  String get ruleOnly;

  /// No description provided for @folderRulesFooter.
  ///
  /// In en, this message translates to:
  /// **'Muted and archived chats: keep them, leave them out, or show only them.'**
  String get folderRulesFooter;

  /// No description provided for @folderReorderHint.
  ///
  /// In en, this message translates to:
  /// **'Hold a tab and drag it to move it.'**
  String get folderReorderHint;

  /// No description provided for @verifyScan.
  ///
  /// In en, this message translates to:
  /// **'Scan their code'**
  String get verifyScan;

  /// No description provided for @verifyScanMatch.
  ///
  /// In en, this message translates to:
  /// **'The codes match — {name} is verified.'**
  String verifyScanMatch(String name);

  /// No description provided for @verifyScanMismatch.
  ///
  /// In en, this message translates to:
  /// **'The codes don\'t match. Don\'t mark this contact as verified — compare the numbers in person.'**
  String get verifyScanMismatch;

  /// No description provided for @verifyScanNotCode.
  ///
  /// In en, this message translates to:
  /// **'This QR isn’t a Sinhron check code.'**
  String get verifyScanNotCode;

  /// No description provided for @recordVideo.
  ///
  /// In en, this message translates to:
  /// **'Record video'**
  String get recordVideo;

  /// No description provided for @videoFromLibrary.
  ///
  /// In en, this message translates to:
  /// **'Choose from library'**
  String get videoFromLibrary;

  /// No description provided for @requestTitle.
  ///
  /// In en, this message translates to:
  /// **'Message request'**
  String get requestTitle;

  /// No description provided for @requestBody.
  ///
  /// In en, this message translates to:
  /// **'Until you accept, they won\'t see that you\'ve read their messages or learn your name, and calls from this chat won\'t ring.'**
  String get requestBody;

  /// No description provided for @requestAccept.
  ///
  /// In en, this message translates to:
  /// **'Accept'**
  String get requestAccept;

  /// No description provided for @screenRecordingByMe.
  ///
  /// In en, this message translates to:
  /// **'You are recording the screen'**
  String get screenRecordingByMe;

  /// No description provided for @screenRecordingByPeer.
  ///
  /// In en, this message translates to:
  /// **'{name} is recording the screen'**
  String screenRecordingByPeer(String name);

  /// No description provided for @screenshotByMe.
  ///
  /// In en, this message translates to:
  /// **'You took a screenshot'**
  String get screenshotByMe;

  /// No description provided for @screenshotByPeer.
  ///
  /// In en, this message translates to:
  /// **'{name} took a screenshot'**
  String screenshotByPeer(String name);

  /// No description provided for @requestBlockFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t block — try again when you\'re connected.'**
  String get requestBlockFailed;

  /// No description provided for @errVideoTooLarge.
  ///
  /// In en, this message translates to:
  /// **'This video is too large to send (95 MB at most), even compressed.'**
  String get errVideoTooLarge;

  /// No description provided for @profileEditChoosePhoto.
  ///
  /// In en, this message translates to:
  /// **'Choose photo'**
  String get profileEditChoosePhoto;

  /// No description provided for @profileEditRemovePhoto.
  ///
  /// In en, this message translates to:
  /// **'Remove photo'**
  String get profileEditRemovePhoto;

  /// ADR-035 group membership
  ///
  /// In en, this message translates to:
  /// **'You were removed from this group.'**
  String get groupYouWereRemoved;

  /// ADR-035 group membership
  ///
  /// In en, this message translates to:
  /// **'{name} left the group.'**
  String groupMemberLeft(String name);

  /// ADR-035 group membership
  ///
  /// In en, this message translates to:
  /// **'You removed {names}.'**
  String groupYouRemoved(String names);

  /// mls-identity:3 group membership
  ///
  /// In en, this message translates to:
  /// **'{by} added {names}.'**
  String groupSomeoneAdded(String by, String names);

  /// ADR-035 group membership
  ///
  /// In en, this message translates to:
  /// **'{by} removed {names}.'**
  String groupSomeoneRemoved(String by, String names);

  /// ADR-035 group membership
  ///
  /// In en, this message translates to:
  /// **'You renamed the group to “{name}”.'**
  String groupYouRenamed(String name);

  /// ADR-035 group membership
  ///
  /// In en, this message translates to:
  /// **'{by} renamed the group to “{name}”.'**
  String groupSomeoneRenamed(String by, String name);

  /// ADR-035 group membership
  ///
  /// In en, this message translates to:
  /// **'Leave group'**
  String get groupLeave;

  /// ADR-035 group membership
  ///
  /// In en, this message translates to:
  /// **'Leave “{name}”? You won’t get its messages any more, and the chat is removed from this device.'**
  String groupLeaveConfirm(String name);

  /// ADR-035 group membership
  ///
  /// In en, this message translates to:
  /// **'Rename group'**
  String get groupRename;

  /// ADR-035 group membership
  ///
  /// In en, this message translates to:
  /// **'Remove from group'**
  String get groupRemoveMember;

  /// ADR-035 group membership
  ///
  /// In en, this message translates to:
  /// **'Remove {name} from the group? They won’t be able to read new messages.'**
  String groupRemoveConfirm(String name);

  /// ADR-035 group membership
  ///
  /// In en, this message translates to:
  /// **'admin'**
  String get groupAdmin;

  /// ADR-035 group membership
  ///
  /// In en, this message translates to:
  /// **'You’re no longer a member of this group.'**
  String get groupNotMember;

  /// ADR-035 group membership
  ///
  /// In en, this message translates to:
  /// **'Couldn’t do that — check your connection and try again.'**
  String get groupActionFailed;

  /// Overnight item 5 — call outcomes
  ///
  /// In en, this message translates to:
  /// **'Missed call'**
  String get chatMissedCall;

  /// Overnight item 5 — call outcomes
  ///
  /// In en, this message translates to:
  /// **'Missed video call'**
  String get chatMissedVideoCall;

  /// Overnight item 5 — call outcomes
  ///
  /// In en, this message translates to:
  /// **'No answer'**
  String get callNoAnswer;

  /// No description provided for @callCouldntConnect.
  ///
  /// In en, this message translates to:
  /// **'Couldn’t connect the call'**
  String get callCouldntConnect;

  /// Security review 2026-11 (calls:1) — a track came without SFrame encryption
  ///
  /// In en, this message translates to:
  /// **'Call ended: the server tried to turn off encryption'**
  String get callNotEncrypted;

  /// Overnight item 5 — call outcomes
  ///
  /// In en, this message translates to:
  /// **'Busy'**
  String get callBusy;

  /// Overnight item 5 — call outcomes
  ///
  /// In en, this message translates to:
  /// **'Declined'**
  String get callDeclinedByPeer;

  /// Overnight item 5 — call outcomes
  ///
  /// In en, this message translates to:
  /// **'Missed call'**
  String get callMissedShort;

  /// Overnight item 5 — call outcomes
  ///
  /// In en, this message translates to:
  /// **'Busy'**
  String get callsBusy;

  /// Overnight item 5 — call outcomes
  ///
  /// In en, this message translates to:
  /// **'Cancelled'**
  String get callsCancelled;

  /// Overnight item 5 — call outcomes
  ///
  /// In en, this message translates to:
  /// **'Missed'**
  String get callsMissedOne;

  /// Overnight item 5 — call outcomes
  ///
  /// In en, this message translates to:
  /// **'Call back'**
  String get callsCallBack;

  /// Overnight item 5 — call outcomes
  ///
  /// In en, this message translates to:
  /// **'Open chat'**
  String get callsOpenChat;

  /// Tech-debt 2.32 — real Storage screen
  ///
  /// In en, this message translates to:
  /// **'Other'**
  String get storageOther;

  /// Tech-debt 2.32 — real Storage screen
  ///
  /// In en, this message translates to:
  /// **'Messages'**
  String get storageDatabase;

  /// Tech-debt 2.32 — real Storage screen
  ///
  /// In en, this message translates to:
  /// **'used by Sinhron on this phone'**
  String get storageUsedHere;

  /// Tech-debt 2.32 — real Storage screen
  ///
  /// In en, this message translates to:
  /// **'Copies of photos, videos, voice messages and files kept on this phone, by chat.'**
  String get storageTopChatsRealFooter;

  /// Tech-debt 2.32 — real Storage screen
  ///
  /// In en, this message translates to:
  /// **'Delete media copies'**
  String get storageClearCopies;

  /// Tech-debt 2.32 — real Storage screen
  ///
  /// In en, this message translates to:
  /// **'Delete the copies of photos, videos and files kept on this phone? Messages stay. A file loads from the server again when you open it — but one the server has already deleted (90 days after anyone last opened it) won’t come back.'**
  String get storageClearCopiesConfirm;

  /// Tech-debt 2.32 — real Storage screen
  ///
  /// In en, this message translates to:
  /// **'Freed {size}'**
  String storageCopiesCleared(String size);

  /// Tech-debt 2.32 — real Storage screen
  ///
  /// In en, this message translates to:
  /// **'Media copies let files open without the internet and keep them after the server deletes old files. Messages and their text are never deleted here.'**
  String get storageClearCopiesFooter;

  /// ADR-037 — account deletion, reports, rules
  ///
  /// In en, this message translates to:
  /// **'DELETE'**
  String get deleteAccountWord;

  /// ADR-037 — account deletion, reports, rules
  ///
  /// In en, this message translates to:
  /// **'This can’t be undone'**
  String get deleteAccountCannotUndo;

  /// ADR-037 — account deletion, reports, rules
  ///
  /// In en, this message translates to:
  /// **'Your account is removed from {server} right away: your address, devices and messages waiting for you.'**
  String deleteAccountServer(String server);

  /// ADR-037 — account deletion, reports, rules
  ///
  /// In en, this message translates to:
  /// **'Your groups are told you left; people can no longer write to you.'**
  String get deleteAccountGroups;

  /// ADR-037 — account deletion, reports, rules
  ///
  /// In en, this message translates to:
  /// **'Chats, media and keys are erased from this phone.'**
  String get deleteAccountThisPhone;

  /// ADR-037 — account deletion, reports, rules
  ///
  /// In en, this message translates to:
  /// **'{n, plural, =1{Your other device stops working.} other{Your {n} other devices stop working.}}'**
  String deleteAccountOtherDevices(int n);

  /// ADR-037 — account deletion, reports, rules
  ///
  /// In en, this message translates to:
  /// **'Messages and files you already sent stay with the people who received them.'**
  String get deleteAccountSentStays;

  /// ADR-037 — account deletion, reports, rules
  ///
  /// In en, this message translates to:
  /// **'Your 24 words can register again, but these chats and groups won’t come back. The chat backup is deleted from iCloud / Google Drive too, if this phone can reach it.'**
  String get deleteAccountPhrase;

  /// ADR-037 — account deletion, reports, rules
  ///
  /// In en, this message translates to:
  /// **'Type {word} to confirm'**
  String deleteAccountTypeWord(String word);

  /// ADR-037 — account deletion, reports, rules
  ///
  /// In en, this message translates to:
  /// **'Couldn’t delete the account — check your connection and try again. Nothing was erased.'**
  String get deleteAccountFailed;

  /// ADR-037 — account deletion, reports, rules
  ///
  /// In en, this message translates to:
  /// **'Report'**
  String get reportAction;

  /// ADR-037 — account deletion, reports, rules
  ///
  /// In en, this message translates to:
  /// **'Report {name}?'**
  String reportTitle(String name);

  /// ADR-037 — account deletion, reports, rules
  ///
  /// In en, this message translates to:
  /// **'The report goes to the operator of {server}. They can’t read your chats — only what you choose to send.'**
  String reportBody(String server);

  /// ADR-037 — account deletion, reports, rules
  ///
  /// In en, this message translates to:
  /// **'Report and send this message'**
  String get reportWithMessage;

  /// ADR-037 — account deletion, reports, rules
  ///
  /// In en, this message translates to:
  /// **'Report without the message'**
  String get reportWithoutMessage;

  /// ADR-037 — account deletion, reports, rules
  ///
  /// In en, this message translates to:
  /// **'Report and block'**
  String get reportAndBlock;

  /// ADR-037 — account deletion, reports, rules
  ///
  /// In en, this message translates to:
  /// **'What’s wrong?'**
  String get reportReasonTitle;

  /// ADR-037 — account deletion, reports, rules
  ///
  /// In en, this message translates to:
  /// **'Spam'**
  String get reportReasonSpam;

  /// ADR-037 — account deletion, reports, rules
  ///
  /// In en, this message translates to:
  /// **'Harassment or threats'**
  String get reportReasonAbuse;

  /// ADR-037 — account deletion, reports, rules
  ///
  /// In en, this message translates to:
  /// **'Illegal content'**
  String get reportReasonIllegal;

  /// ADR-037 — account deletion, reports, rules
  ///
  /// In en, this message translates to:
  /// **'Something else'**
  String get reportReasonOther;

  /// ADR-037 — account deletion, reports, rules
  ///
  /// In en, this message translates to:
  /// **'Report sent. Thank you.'**
  String get reportSent;

  /// ADR-037 — account deletion, reports, rules
  ///
  /// In en, this message translates to:
  /// **'Couldn’t send the report — check your connection and try again.'**
  String get reportFailed;

  /// ADR-037 — account deletion, reports, rules
  ///
  /// In en, this message translates to:
  /// **'Help & rules'**
  String get legalSection;

  /// ADR-037 — account deletion, reports, rules
  ///
  /// In en, this message translates to:
  /// **'Terms of use'**
  String get legalTermsRow;

  /// ADR-037 — account deletion, reports, rules
  ///
  /// In en, this message translates to:
  /// **'Privacy policy'**
  String get legalPrivacyRow;

  /// No description provided for @reportProblemTitle.
  ///
  /// In en, this message translates to:
  /// **'Report a problem'**
  String get reportProblemTitle;

  /// No description provided for @reportProblemHint.
  ///
  /// In en, this message translates to:
  /// **'Send the app’s log to whoever helps you'**
  String get reportProblemHint;

  /// No description provided for @reportProblemNoteHint.
  ///
  /// In en, this message translates to:
  /// **'What happened? E.g. “the call connected but there was no sound”'**
  String get reportProblemNoteHint;

  /// No description provided for @reportProblemWhat.
  ///
  /// In en, this message translates to:
  /// **'The report holds the app’s log for the last hour — connection, notifications, calls — the app version and phone model. No message text, names or keys.'**
  String get reportProblemWhat;

  /// No description provided for @reportProblemPreview.
  ///
  /// In en, this message translates to:
  /// **'View the report'**
  String get reportProblemPreview;

  /// No description provided for @reportProblemHidePreview.
  ///
  /// In en, this message translates to:
  /// **'Hide the report'**
  String get reportProblemHidePreview;

  /// No description provided for @reportProblemSend.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get reportProblemSend;

  /// No description provided for @reportProblemCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get reportProblemCopy;

  /// No description provided for @reportProblemCopied.
  ///
  /// In en, this message translates to:
  /// **'Report copied'**
  String get reportProblemCopied;

  /// No description provided for @pasteMarkdownDone.
  ///
  /// In en, this message translates to:
  /// **'Markdown turned into formatting'**
  String get pasteMarkdownDone;

  /// No description provided for @pasteMarkdownRevert.
  ///
  /// In en, this message translates to:
  /// **'Undo'**
  String get pasteMarkdownRevert;

  /// No description provided for @reportProblemFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn’t put the report together. Try again.'**
  String get reportProblemFailed;

  /// No description provided for @reportProblemSendHint.
  ///
  /// In en, this message translates to:
  /// **'Send opens the share menu: pick Sinhron and the chat with the person who helps you — or Telegram or mail if Sinhron can’t connect.'**
  String get reportProblemSendHint;

  /// No description provided for @backupTitle.
  ///
  /// In en, this message translates to:
  /// **'Chat backup'**
  String get backupTitle;

  /// No description provided for @backupHint.
  ///
  /// In en, this message translates to:
  /// **'Your chats and media, in your own cloud'**
  String get backupHint;

  /// No description provided for @backupWhere.
  ///
  /// In en, this message translates to:
  /// **'Kept in'**
  String get backupWhere;

  /// No description provided for @backupWhereDrive.
  ///
  /// In en, this message translates to:
  /// **'Google Drive'**
  String get backupWhereDrive;

  /// No description provided for @backupNotConnected.
  ///
  /// In en, this message translates to:
  /// **'Not connected'**
  String get backupNotConnected;

  /// No description provided for @backupSignInGoogle.
  ///
  /// In en, this message translates to:
  /// **'Sign in with Google'**
  String get backupSignInGoogle;

  /// No description provided for @backupSignOutGoogle.
  ///
  /// In en, this message translates to:
  /// **'Sign out of Google'**
  String get backupSignOutGoogle;

  /// No description provided for @backupIcloudOff.
  ///
  /// In en, this message translates to:
  /// **'Turn on iCloud Drive in the iPhone’s settings (your name → iCloud → iCloud Drive)'**
  String get backupIcloudOff;

  /// No description provided for @backupDaily.
  ///
  /// In en, this message translates to:
  /// **'Back up every day'**
  String get backupDaily;

  /// No description provided for @backupLast.
  ///
  /// In en, this message translates to:
  /// **'Last backup'**
  String get backupLast;

  /// No description provided for @backupNever.
  ///
  /// In en, this message translates to:
  /// **'Not yet'**
  String get backupNever;

  /// No description provided for @backupNow.
  ///
  /// In en, this message translates to:
  /// **'Back up now'**
  String get backupNow;

  /// No description provided for @backupRunning.
  ///
  /// In en, this message translates to:
  /// **'Backing up…'**
  String get backupRunning;

  /// No description provided for @backupRunningMedia.
  ///
  /// In en, this message translates to:
  /// **'Media {done} of {total}'**
  String backupRunningMedia(int done, int total);

  /// No description provided for @backupFailed.
  ///
  /// In en, this message translates to:
  /// **'Didn’t finish. Check the internet and try again.'**
  String get backupFailed;

  /// No description provided for @backupDone.
  ///
  /// In en, this message translates to:
  /// **'Backup saved'**
  String get backupDone;

  /// No description provided for @backupRestoreSection.
  ///
  /// In en, this message translates to:
  /// **'Restore'**
  String get backupRestoreSection;

  /// No description provided for @backupRestore.
  ///
  /// In en, this message translates to:
  /// **'Restore from backup'**
  String get backupRestore;

  /// No description provided for @backupRestoreNone.
  ///
  /// In en, this message translates to:
  /// **'No backup found in {where}'**
  String backupRestoreNone(String where);

  /// No description provided for @backupRestoreAskTitle.
  ///
  /// In en, this message translates to:
  /// **'Restore your chats?'**
  String get backupRestoreAskTitle;

  /// No description provided for @backupRestoreAskBody.
  ///
  /// In en, this message translates to:
  /// **'Backup of {date}: {messages} messages in {chats} chats, {media} media files.'**
  String backupRestoreAskBody(String date, int messages, int chats, int media);

  /// No description provided for @backupRestoreOlder.
  ///
  /// In en, this message translates to:
  /// **'A newer backup ({newer}) is not in the cloud any more — this one is older. Messages after it will be missing.'**
  String backupRestoreOlder(String newer);

  /// No description provided for @backupRestoreGo.
  ///
  /// In en, this message translates to:
  /// **'Restore'**
  String get backupRestoreGo;

  /// No description provided for @backupRestoring.
  ///
  /// In en, this message translates to:
  /// **'Restoring… {done} of {total}'**
  String backupRestoring(int done, int total);

  /// No description provided for @backupRestored.
  ///
  /// In en, this message translates to:
  /// **'Chats restored'**
  String get backupRestored;

  /// No description provided for @backupRestoredAdded.
  ///
  /// In en, this message translates to:
  /// **'Chats restored: {n} messages added'**
  String backupRestoredAdded(int n);

  /// No description provided for @backupRestoredNothingNew.
  ///
  /// In en, this message translates to:
  /// **'Nothing new in the backup — it’s all here already'**
  String get backupRestoredNothingNew;

  /// No description provided for @backupUploadPending.
  ///
  /// In en, this message translates to:
  /// **'Still uploading to iCloud — your other devices see it once this iPhone sends it (usually on Wi‑Fi)'**
  String get backupUploadPending;

  /// No description provided for @backupFooter.
  ///
  /// In en, this message translates to:
  /// **'The backup is encrypted with your 24 secret words: neither Apple nor Google can read it, and without the words it can’t be restored.'**
  String get backupFooter;

  /// No description provided for @backupUnlockRow.
  ///
  /// In en, this message translates to:
  /// **'Turn on backup on this device'**
  String get backupUnlockRow;

  /// No description provided for @backupUnlockRowHint.
  ///
  /// In en, this message translates to:
  /// **'Needs your 24 words — once'**
  String get backupUnlockRowHint;

  /// No description provided for @backupUnlockTitle.
  ///
  /// In en, this message translates to:
  /// **'Turn on backup here'**
  String get backupUnlockTitle;

  /// No description provided for @backupUnlockBody.
  ///
  /// In en, this message translates to:
  /// **'This device was linked before backups existed. Type your 24 words once — the words themselves aren’t kept.'**
  String get backupUnlockBody;

  /// No description provided for @backupUnlockGo.
  ///
  /// In en, this message translates to:
  /// **'Turn on'**
  String get backupUnlockGo;

  /// No description provided for @backupUnlockOtherWords.
  ///
  /// In en, this message translates to:
  /// **'These are another account’s words'**
  String get backupUnlockOtherWords;

  /// No description provided for @backupOfferDriveTitle.
  ///
  /// In en, this message translates to:
  /// **'Look for a chat backup in Google Drive?'**
  String get backupOfferDriveTitle;

  /// No description provided for @backupOfferDriveBody.
  ///
  /// In en, this message translates to:
  /// **'If your old phone made a backup, your chats come back. Sign in to the same Google account.'**
  String get backupOfferDriveBody;

  /// No description provided for @backupOfferDriveGo.
  ///
  /// In en, this message translates to:
  /// **'Sign in with Google'**
  String get backupOfferDriveGo;

  /// No description provided for @backupRestoreStarted.
  ///
  /// In en, this message translates to:
  /// **'Restoring your chats — you can use the app meanwhile'**
  String get backupRestoreStarted;

  /// No description provided for @oldDevicesTitle.
  ///
  /// In en, this message translates to:
  /// **'Your other devices'**
  String get oldDevicesTitle;

  /// No description provided for @oldDevicesBody.
  ///
  /// In en, this message translates to:
  /// **'If your old phone is lost, sold or broken, disconnect it: it gets no more messages or calls and leaves your chats. Only now, while your 24 words are in.'**
  String get oldDevicesBody;

  /// No description provided for @oldDevicesDisconnect.
  ///
  /// In en, this message translates to:
  /// **'Disconnect'**
  String get oldDevicesDisconnect;

  /// No description provided for @oldDevicesDisconnected.
  ///
  /// In en, this message translates to:
  /// **'Disconnected'**
  String get oldDevicesDisconnected;

  /// ADR-037 — account deletion, reports, rules
  ///
  /// In en, this message translates to:
  /// **'Help & support'**
  String get legalSupportRow;

  /// ADR-037 — account deletion, reports, rules
  ///
  /// In en, this message translates to:
  /// **'By using Sinhron you agree to these rules. They apply to everyone on this server.'**
  String get legalTermsIntro;

  /// ADR-037 — account deletion, reports, rules
  ///
  /// In en, this message translates to:
  /// **'No tolerance for objectionable content or abusive people. Don’t send spam, threats, harassment, hate, sexual content involving minors, or anything illegal where you or the recipient live.\n\nReport and block. In any chat you can report a person or a message. The report goes to the operator of your server, who reviews it and may remove the account — usually within 24 hours. Blocking hides a person from you at once.\n\nYour messages are end-to-end encrypted: the operator can’t read them. A report contains only what you choose to send.\n\nThe operator may remove accounts that break these rules. You can delete your account at any time in Profile → Delete account.'**
  String get legalTermsBody;

  /// ADR-037 — account deletion, reports, rules
  ///
  /// In en, this message translates to:
  /// **'Messages, calls, photos and files are encrypted on your devices; the server only passes them along encrypted and can’t read them.\n\nThe server knows: your Sinhron address, your devices, which groups you are in, and when messages are sent — that is what it needs to deliver them. It doesn’t know your name, photo, contacts or message content.\n\nNothing is sold or shared with advertisers. No ads, no analytics.\n\nDelete your account at any time (Profile → Delete account): the server removes your address, devices and messages waiting for you.'**
  String get legalPrivacyBody;

  /// ADR-037 — account deletion, reports, rules
  ///
  /// In en, this message translates to:
  /// **'Questions, problems, a report about someone: write to the operator of your server.'**
  String get legalSupportBody;

  /// ADR-037 — account deletion, reports, rules
  ///
  /// In en, this message translates to:
  /// **'Server: {server}'**
  String legalSupportOperator(String server);

  /// ADR-037 — account deletion, reports, rules
  ///
  /// In en, this message translates to:
  /// **'To report a person or a message, long-press the message or open the chat’s info and choose Report.'**
  String get legalSupportReportHint;

  /// ADR-037 — under the onboarding buttons; opens the terms
  ///
  /// In en, this message translates to:
  /// **'By continuing you accept the Terms of use'**
  String get welcomeAgreeTerms;

  /// Overnight item 8 — push
  ///
  /// In en, this message translates to:
  /// **'Message notifications'**
  String get pushToggle;

  /// Overnight item 8 — push
  ///
  /// In en, this message translates to:
  /// **'When Sinhron is closed, your phone shows “New message” — no text and no name: your server can’t read messages. Previews come with a future version.'**
  String get pushFooterOn;

  /// Overnight item 8 — push
  ///
  /// In en, this message translates to:
  /// **'Notifications are off in iOS Settings → Sinhron → Notifications.'**
  String get pushDenied;

  /// ADR-040 — Android without a UnifiedPush distributor
  ///
  /// In en, this message translates to:
  /// **'There’s no notification app on this phone. Install ntfy (Google Play or F-Droid) — Sinhron wakes the phone through it. Which server to set in ntfy shows here once Sinhron is online.'**
  String get pushNoDistributor;

  /// ADR-040 fallback without ntfy
  ///
  /// In en, this message translates to:
  /// **'Always connected'**
  String get keepConnected;

  /// ADR-040 fallback without ntfy
  ///
  /// In en, this message translates to:
  /// **'Only needed if calls and messages don’t arrive while Sinhron is closed. It usually turns on and off by itself: when it isn’t needed it only drains the battery.'**
  String get keepConnectedFooter;

  /// ADR-057 — will calls reach this Android phone
  ///
  /// In en, this message translates to:
  /// **'Calls will reach you: yes'**
  String get callsReachYes;

  /// ADR-057 — will calls reach this Android phone
  ///
  /// In en, this message translates to:
  /// **'Calls will reach you: not yet — what to do'**
  String get callsReachNo;

  /// ADR-057 — will calls reach this Android phone
  ///
  /// In en, this message translates to:
  /// **'Even when Sinhron is closed or swiped away. Google only sees that something came for Sinhron, not what or from whom.'**
  String get callsReachViaGoogle;

  /// ADR-057 — will calls reach this Android phone
  ///
  /// In en, this message translates to:
  /// **'Even when Sinhron is closed.'**
  String get callsReachViaNtfy;

  /// ADR-057 — will calls reach this Android phone
  ///
  /// In en, this message translates to:
  /// **'Through “Always connected”: Sinhron stays online in the background.'**
  String get callsReachViaAlways;

  /// ADR-057 — will calls reach this Android phone
  ///
  /// In en, this message translates to:
  /// **'Nothing wakes this phone while Sinhron is closed.'**
  String get callsReachNone;

  /// ADR-057 — will calls reach this Android phone
  ///
  /// In en, this message translates to:
  /// **'Allow notifications'**
  String get reachFixNotifications;

  /// ADR-057 — will calls reach this Android phone
  ///
  /// In en, this message translates to:
  /// **'Turn on incoming calls'**
  String get reachFixCalls;

  /// ADR-057 — will calls reach this Android phone
  ///
  /// In en, this message translates to:
  /// **'Turn on “Always connected”'**
  String get reachFixAlways;

  /// ADR-057 — will calls reach this Android phone
  ///
  /// In en, this message translates to:
  /// **'Let Sinhron run in the background'**
  String get reachFixBackground;

  /// ADR-057 — will calls reach this Android phone
  ///
  /// In en, this message translates to:
  /// **'Samsung: “Never sleeping apps”'**
  String get reachSamsung;

  /// ADR-057 — will calls reach this Android phone
  ///
  /// In en, this message translates to:
  /// **'Add Sinhron there so the phone never puts it to sleep'**
  String get reachSamsungSub;

  /// ADR-040 — which push server to set in the ntfy app
  ///
  /// In en, this message translates to:
  /// **'Notifications through ntfy'**
  String get ntfyTitle;

  /// ADR-040 — which push server to set in the ntfy app
  ///
  /// In en, this message translates to:
  /// **'To wake this phone, Sinhron needs the free ntfy app.\n1. Install ntfy from Google Play or F-Droid.\n2. In ntfy open the ⋮ menu → Settings → Default server and enter {url}\n3. Come back here and tap “Connect ntfy”.'**
  String ntfyInstallSteps(String url);

  /// ADR-040 — which push server to set in the ntfy app
  ///
  /// In en, this message translates to:
  /// **'ntfy is installed but not connected yet.\n1. In ntfy open the ⋮ menu → Settings → Default server and enter {url}\n2. Come back here and tap “Connect ntfy”.'**
  String ntfySetServerSteps(String url);

  /// ADR-040 — which push server to set in the ntfy app
  ///
  /// In en, this message translates to:
  /// **'ntfy uses another server ({other}) — Sinhron notifications don’t come through it.\n1. In ntfy open the ⋮ menu → Settings → Default server and enter {url}\n2. Come back here and tap “Connect ntfy”.'**
  String ntfyOtherServerSteps(String other, String url);

  /// ADR-040 — which push server to set in the ntfy app
  ///
  /// In en, this message translates to:
  /// **'Your Sinhron server doesn’t send notifications to Android phones. Turn on “Always connected” below — then Sinhron stays online by itself.'**
  String get ntfyServerHasNone;

  /// ADR-040 — which push server to set in the ntfy app
  ///
  /// In en, this message translates to:
  /// **'Copy the server address'**
  String get ntfyCopyAddress;

  /// ADR-040 — which push server to set in the ntfy app
  ///
  /// In en, this message translates to:
  /// **'Address copied'**
  String get ntfyAddressCopied;

  /// ADR-040 — which push server to set in the ntfy app
  ///
  /// In en, this message translates to:
  /// **'Install ntfy'**
  String get ntfyInstall;

  /// ADR-040 — which push server to set in the ntfy app
  ///
  /// In en, this message translates to:
  /// **'Open ntfy'**
  String get ntfyOpen;

  /// ADR-040 — which push server to set in the ntfy app
  ///
  /// In en, this message translates to:
  /// **'Connect ntfy'**
  String get ntfyConnect;

  /// ADR-040 — which push server to set in the ntfy app
  ///
  /// In en, this message translates to:
  /// **'Connecting ntfy…'**
  String get ntfyConnecting;

  /// No description provided for @asInSystem.
  ///
  /// In en, this message translates to:
  /// **'As in system settings'**
  String get asInSystem;

  /// No description provided for @setPasscodeFirstAndroid.
  ///
  /// In en, this message translates to:
  /// **'Set a screen lock on this phone first — App Lock uses it.'**
  String get setPasscodeFirstAndroid;

  /// No description provided for @appLockFooterAndroid.
  ///
  /// In en, this message translates to:
  /// **'When on, Sinhron asks for your fingerprint, face or screen lock when it opens. Your chats stay encrypted either way.'**
  String get appLockFooterAndroid;

  /// No description provided for @unlockPhraseNoteAndroid.
  ///
  /// In en, this message translates to:
  /// **'The words never leave the phone and aren’t stored — the phone keeps only a key made from them, in Android’s protected storage.'**
  String get unlockPhraseNoteAndroid;

  /// No description provided for @navErrNotConnected.
  ///
  /// In en, this message translates to:
  /// **'No connection to the server — reconnecting. Try again in a few seconds.'**
  String get navErrNotConnected;

  /// No description provided for @callSwitchingPath.
  ///
  /// In en, this message translates to:
  /// **'The call keeps dropping — switching to the backup route…'**
  String get callSwitchingPath;

  /// No description provided for @callsReserveSection.
  ///
  /// In en, this message translates to:
  /// **'Calls'**
  String get callsReserveSection;

  /// No description provided for @callsReserve.
  ///
  /// In en, this message translates to:
  /// **'Calls over the backup route'**
  String get callsReserve;

  /// No description provided for @callsReserveFooter.
  ///
  /// In en, this message translates to:
  /// **'Sound and video go through your server the same way a normal website loads — for networks where calls connect and then drop. Still encrypted. Sinhron also switches by itself when a call keeps dropping.'**
  String get callsReserveFooter;

  /// No description provided for @inviteShareText.
  ///
  /// In en, this message translates to:
  /// **'Join me on Sinhron — an encrypted messenger. Install the app and tap the link, I\'ll be in your contacts right away: {link}'**
  String inviteShareText(String link);

  /// No description provided for @inviteForged.
  ///
  /// In en, this message translates to:
  /// **'This invite link was changed or forged — not opening it. Ask the person to send it again.'**
  String get inviteForged;

  /// No description provided for @inviteDamaged.
  ///
  /// In en, this message translates to:
  /// **'This invite link is damaged. Ask the person to send it again.'**
  String get inviteDamaged;

  /// No description provided for @inviteExpired.
  ///
  /// In en, this message translates to:
  /// **'This link has expired — ask for a new one'**
  String get inviteExpired;

  /// No description provided for @inviteOffline.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t open the invite — no connection to its server. Tap the link again a bit later.'**
  String get inviteOffline;

  /// No description provided for @inviteKeyRow.
  ///
  /// In en, this message translates to:
  /// **'Address {fingerprint}'**
  String inviteKeyRow(String fingerprint);

  /// No description provided for @inviteYourServer.
  ///
  /// In en, this message translates to:
  /// **'Your server'**
  String get inviteYourServer;

  /// No description provided for @inviteAddContact.
  ///
  /// In en, this message translates to:
  /// **'Add {name} to contacts'**
  String inviteAddContact(String name);

  /// No description provided for @inviteServerChecking.
  ///
  /// In en, this message translates to:
  /// **'Checking the server…'**
  String get inviteServerChecking;

  /// No description provided for @inviteServerOk.
  ///
  /// In en, this message translates to:
  /// **'Server is reachable'**
  String get inviteServerOk;

  /// No description provided for @inviteServerUnreachable.
  ///
  /// In en, this message translates to:
  /// **'Server doesn\'t answer right now — you can still go on'**
  String get inviteServerUnreachable;

  /// No description provided for @inviteNotSinhron.
  ///
  /// In en, this message translates to:
  /// **'This address isn\'t a Sinhron server'**
  String get inviteNotSinhron;

  /// No description provided for @inviteNotSaved.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t save the server on this phone — try again'**
  String get inviteNotSaved;

  /// No description provided for @notificationPreviewTitle.
  ///
  /// In en, this message translates to:
  /// **'Notifications show'**
  String get notificationPreviewTitle;

  /// No description provided for @notificationPreviewNameAndText.
  ///
  /// In en, this message translates to:
  /// **'Name and message'**
  String get notificationPreviewNameAndText;

  /// No description provided for @notificationPreviewNameOnly.
  ///
  /// In en, this message translates to:
  /// **'Name only'**
  String get notificationPreviewNameOnly;

  /// No description provided for @notificationPreviewNothing.
  ///
  /// In en, this message translates to:
  /// **'Nothing — just \"New message\"'**
  String get notificationPreviewNothing;

  /// No description provided for @notificationPreviewFooter.
  ///
  /// In en, this message translates to:
  /// **'For banners in the app, Android notifications and the name in the iPhone\'s call history. On an iPhone with Sinhron closed a notification always says just \"New message\": your server can\'t read who wrote or what.'**
  String get notificationPreviewFooter;

  /// No description provided for @callDiagnostics.
  ///
  /// In en, this message translates to:
  /// **'Call diagnostics'**
  String get callDiagnostics;

  /// Call: button that starts showing my phone screen to the others
  ///
  /// In en, this message translates to:
  /// **'Share screen'**
  String get callShareScreen;

  /// Call: banner while my screen is shown
  ///
  /// In en, this message translates to:
  /// **'You\'re sharing your screen'**
  String get callSharingScreen;

  /// Call: stop showing my screen
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get callStopSharing;

  /// Call: title over someone else's shared screen
  ///
  /// In en, this message translates to:
  /// **'{name} is sharing the screen'**
  String callScreenOf(String name);

  /// Call: close the shared-screen viewer
  ///
  /// In en, this message translates to:
  /// **'Back to call'**
  String get callScreenBackToCall;

  /// Call: reopen someone's shared screen
  ///
  /// In en, this message translates to:
  /// **'Watch screen: {name}'**
  String callScreenWatch(String name);

  /// Call: rotate the shared screen
  ///
  /// In en, this message translates to:
  /// **'Rotate'**
  String get callScreenRotate;

  /// Call: screen sharing did not start
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t share the screen'**
  String get callScreenShareFailed;

  /// No description provided for @callAudioOutput.
  ///
  /// In en, this message translates to:
  /// **'Audio output'**
  String get callAudioOutput;

  /// No description provided for @callAudioPhone.
  ///
  /// In en, this message translates to:
  /// **'Phone'**
  String get callAudioPhone;

  /// No description provided for @callAudioHeadphones.
  ///
  /// In en, this message translates to:
  /// **'Headphones'**
  String get callAudioHeadphones;

  /// No description provided for @callAudioCar.
  ///
  /// In en, this message translates to:
  /// **'Car'**
  String get callAudioCar;

  /// No description provided for @callAudioOther.
  ///
  /// In en, this message translates to:
  /// **'Other device'**
  String get callAudioOther;

  /// No description provided for @callKeepsDropping.
  ///
  /// In en, this message translates to:
  /// **'The call keeps dropping. If a VPN is on, try turning it off'**
  String get callKeepsDropping;

  /// No description provided for @searchCalls.
  ///
  /// In en, this message translates to:
  /// **'Search calls'**
  String get searchCalls;

  /// No description provided for @callsNewCallTitle.
  ///
  /// In en, this message translates to:
  /// **'Call whom?'**
  String get callsNewCallTitle;

  /// No description provided for @storageKeepCopies.
  ///
  /// In en, this message translates to:
  /// **'Keep media copies'**
  String get storageKeepCopies;

  /// No description provided for @storageKeepForever.
  ///
  /// In en, this message translates to:
  /// **'Forever'**
  String get storageKeepForever;

  /// No description provided for @storageKeepMonth.
  ///
  /// In en, this message translates to:
  /// **'A month'**
  String get storageKeepMonth;

  /// No description provided for @storageKeepWeek.
  ///
  /// In en, this message translates to:
  /// **'A week'**
  String get storageKeepWeek;

  /// No description provided for @storageKeepFooter.
  ///
  /// In en, this message translates to:
  /// **'A copy nobody opened for that long is deleted from this phone; the message stays and the file loads from the server again while the server has it (90 days after anyone last loaded it).'**
  String get storageKeepFooter;

  /// No description provided for @emojiRecent.
  ///
  /// In en, this message translates to:
  /// **'Recent'**
  String get emojiRecent;

  /// No description provided for @emojiSmileys.
  ///
  /// In en, this message translates to:
  /// **'Smileys & Emotion'**
  String get emojiSmileys;

  /// No description provided for @emojiPeople.
  ///
  /// In en, this message translates to:
  /// **'People & Body'**
  String get emojiPeople;

  /// No description provided for @emojiAnimals.
  ///
  /// In en, this message translates to:
  /// **'Animals & Nature'**
  String get emojiAnimals;

  /// No description provided for @emojiFood.
  ///
  /// In en, this message translates to:
  /// **'Food & Drink'**
  String get emojiFood;

  /// No description provided for @emojiActivities.
  ///
  /// In en, this message translates to:
  /// **'Activity'**
  String get emojiActivities;

  /// No description provided for @emojiTravel.
  ///
  /// In en, this message translates to:
  /// **'Travel & Places'**
  String get emojiTravel;

  /// No description provided for @emojiObjects.
  ///
  /// In en, this message translates to:
  /// **'Objects'**
  String get emojiObjects;

  /// No description provided for @emojiSymbols.
  ///
  /// In en, this message translates to:
  /// **'Symbols'**
  String get emojiSymbols;

  /// No description provided for @emojiFlags.
  ///
  /// In en, this message translates to:
  /// **'Flags'**
  String get emojiFlags;

  /// No description provided for @emojiDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get emojiDelete;

  /// No description provided for @emojiKeyboard.
  ///
  /// In en, this message translates to:
  /// **'Keyboard'**
  String get emojiKeyboard;

  /// No description provided for @emojiTab.
  ///
  /// In en, this message translates to:
  /// **'Emoji'**
  String get emojiTab;

  /// No description provided for @stickersTab.
  ///
  /// In en, this message translates to:
  /// **'Stickers'**
  String get stickersTab;

  /// No description provided for @emojiSearch.
  ///
  /// In en, this message translates to:
  /// **'Search emoji'**
  String get emojiSearch;

  /// No description provided for @emojiNothingFound.
  ///
  /// In en, this message translates to:
  /// **'Nothing found'**
  String get emojiNothingFound;

  /// No description provided for @emojiSkinTone.
  ///
  /// In en, this message translates to:
  /// **'Skin tone'**
  String get emojiSkinTone;

  /// No description provided for @stickersAdd.
  ///
  /// In en, this message translates to:
  /// **'Add stickers'**
  String get stickersAdd;

  /// No description provided for @stickersFromFiles.
  ///
  /// In en, this message translates to:
  /// **'From files — .tgs, .webp, .webm, .zip'**
  String get stickersFromFiles;

  /// No description provided for @stickersFromCode.
  ///
  /// In en, this message translates to:
  /// **'Paste a link or pack code'**
  String get stickersFromCode;

  /// No description provided for @stickersNoCode.
  ///
  /// In en, this message translates to:
  /// **'Copy a t.me/addstickers/… link or a pack code, then tap again'**
  String get stickersNoCode;

  /// No description provided for @stickersImporting.
  ///
  /// In en, this message translates to:
  /// **'Adding stickers…'**
  String get stickersImporting;

  /// No description provided for @stickersImportFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t add stickers: no usable files'**
  String get stickersImportFailed;

  /// No description provided for @stickersImported.
  ///
  /// In en, this message translates to:
  /// **'Pack “{title}” added'**
  String stickersImported(String title);

  /// No description provided for @myStickersTitle.
  ///
  /// In en, this message translates to:
  /// **'My stickers'**
  String get myStickersTitle;

  /// No description provided for @stickersAll.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get stickersAll;

  /// No description provided for @stickersFound.
  ///
  /// In en, this message translates to:
  /// **'Found'**
  String get stickersFound;

  /// No description provided for @stickersNone.
  ///
  /// In en, this message translates to:
  /// **'No stickers with {emoji}'**
  String stickersNone(String emoji);

  /// No description provided for @stickerPackAdd.
  ///
  /// In en, this message translates to:
  /// **'Add {count, plural, one{{count} sticker} other{{count} stickers}}'**
  String stickerPackAdd(int count);

  /// No description provided for @stickerPackAdded.
  ///
  /// In en, this message translates to:
  /// **'Pack added'**
  String get stickerPackAdded;

  /// No description provided for @stickerPackAlready.
  ///
  /// In en, this message translates to:
  /// **'You already have this pack'**
  String get stickerPackAlready;

  /// No description provided for @stickerPackShare.
  ///
  /// In en, this message translates to:
  /// **'Share pack'**
  String get stickerPackShare;

  /// No description provided for @stickerPackCopyCode.
  ///
  /// In en, this message translates to:
  /// **'Copy pack code'**
  String get stickerPackCopyCode;

  /// No description provided for @stickerPackCodeCopied.
  ///
  /// In en, this message translates to:
  /// **'Pack code copied'**
  String get stickerPackCodeCopied;

  /// No description provided for @stickerPackShareText.
  ///
  /// In en, this message translates to:
  /// **'My stickers for Sinhron — in the sticker panel tap + and paste this code: {code}'**
  String stickerPackShareText(String code);

  /// No description provided for @stickerPackDelete.
  ///
  /// In en, this message translates to:
  /// **'Remove pack'**
  String get stickerPackDelete;

  /// No description provided for @stickerPackBuiltin.
  ///
  /// In en, this message translates to:
  /// **'Built-in pack'**
  String get stickerPackBuiltin;

  /// No description provided for @stickerPackCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{{count} sticker} other{{count} stickers}}'**
  String stickerPackCount(int count);

  /// No description provided for @stickerPackUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t open the pack — check the connection'**
  String get stickerPackUnavailable;

  /// No description provided for @stickerPackNotShared.
  ///
  /// In en, this message translates to:
  /// **'This sticker came without its pack'**
  String get stickerPackNotShared;

  /// No description provided for @stickerPackOptions.
  ///
  /// In en, this message translates to:
  /// **'Pack options'**
  String get stickerPackOptions;

  /// No description provided for @tgPackFrom.
  ///
  /// In en, this message translates to:
  /// **'From Telegram'**
  String get tgPackFrom;

  /// No description provided for @tgPackLoading.
  ///
  /// In en, this message translates to:
  /// **'Opening the Telegram pack…'**
  String get tgPackLoading;

  /// No description provided for @tgPackDownloading.
  ///
  /// In en, this message translates to:
  /// **'Downloading stickers: {done} of {total}'**
  String tgPackDownloading(int done, int total);

  /// No description provided for @tgPackNotFound.
  ///
  /// In en, this message translates to:
  /// **'Pack not found — check the link'**
  String get tgPackNotFound;

  /// No description provided for @tgPackNotConfigured.
  ///
  /// In en, this message translates to:
  /// **'The server isn\'t set up for Telegram packs yet — ask whoever runs it'**
  String get tgPackNotConfigured;

  /// No description provided for @tgPackServerOld.
  ///
  /// In en, this message translates to:
  /// **'The server can\'t fetch Telegram packs yet — it needs an update'**
  String get tgPackServerOld;

  /// No description provided for @tgPackUnreachable.
  ///
  /// In en, this message translates to:
  /// **'The server can\'t reach Telegram right now — try later'**
  String get tgPackUnreachable;

  /// No description provided for @tgPackRateLimited.
  ///
  /// In en, this message translates to:
  /// **'Too many packs in a row — try again in a few minutes'**
  String get tgPackRateLimited;

  /// No description provided for @tgPackFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load the pack — check the connection'**
  String get tgPackFailed;

  /// No description provided for @tgPackAddToSinhron.
  ///
  /// In en, this message translates to:
  /// **'Add the stickers to Sinhron'**
  String get tgPackAddToSinhron;

  /// No description provided for @tgPackAddedPartly.
  ///
  /// In en, this message translates to:
  /// **'Pack “{title}” added; {count} didn\'t load'**
  String tgPackAddedPartly(String title, int count);

  /// No description provided for @kindSticker.
  ///
  /// In en, this message translates to:
  /// **'Sticker'**
  String get kindSticker;

  /// No description provided for @whatSticker.
  ///
  /// In en, this message translates to:
  /// **'sticker'**
  String get whatSticker;

  /// No description provided for @a11ySticker.
  ///
  /// In en, this message translates to:
  /// **'Sticker {emoji}'**
  String a11ySticker(String emoji);

  /// No description provided for @accentBlue.
  ///
  /// In en, this message translates to:
  /// **'Blue'**
  String get accentBlue;

  /// No description provided for @accentViolet.
  ///
  /// In en, this message translates to:
  /// **'Violet'**
  String get accentViolet;

  /// No description provided for @accentGreen.
  ///
  /// In en, this message translates to:
  /// **'Green'**
  String get accentGreen;

  /// No description provided for @accentOrange.
  ///
  /// In en, this message translates to:
  /// **'Orange'**
  String get accentOrange;

  /// No description provided for @accentPink.
  ///
  /// In en, this message translates to:
  /// **'Pink'**
  String get accentPink;

  /// No description provided for @accentGraphite.
  ///
  /// In en, this message translates to:
  /// **'Graphite'**
  String get accentGraphite;

  /// No description provided for @tapToReveal.
  ///
  /// In en, this message translates to:
  /// **'Tap to reveal'**
  String get tapToReveal;

  /// No description provided for @textSelectAll.
  ///
  /// In en, this message translates to:
  /// **'Select All'**
  String get textSelectAll;

  /// No description provided for @textPaste.
  ///
  /// In en, this message translates to:
  /// **'Paste'**
  String get textPaste;

  /// No description provided for @textCut.
  ///
  /// In en, this message translates to:
  /// **'Cut'**
  String get textCut;

  /// No description provided for @formatMenu.
  ///
  /// In en, this message translates to:
  /// **'Format'**
  String get formatMenu;

  /// No description provided for @formatBold.
  ///
  /// In en, this message translates to:
  /// **'Bold'**
  String get formatBold;

  /// No description provided for @formatItalic.
  ///
  /// In en, this message translates to:
  /// **'Italic'**
  String get formatItalic;

  /// No description provided for @formatUnderline.
  ///
  /// In en, this message translates to:
  /// **'Underline'**
  String get formatUnderline;

  /// No description provided for @formatStrike.
  ///
  /// In en, this message translates to:
  /// **'Strikethrough'**
  String get formatStrike;

  /// No description provided for @formatMono.
  ///
  /// In en, this message translates to:
  /// **'Monospace'**
  String get formatMono;

  /// No description provided for @formatSpoiler.
  ///
  /// In en, this message translates to:
  /// **'Spoiler'**
  String get formatSpoiler;

  /// No description provided for @formatLink.
  ///
  /// In en, this message translates to:
  /// **'Link'**
  String get formatLink;

  /// No description provided for @formatQuote.
  ///
  /// In en, this message translates to:
  /// **'Quote'**
  String get formatQuote;

  /// No description provided for @formatClear.
  ///
  /// In en, this message translates to:
  /// **'Clear formatting'**
  String get formatClear;

  /// No description provided for @linkSheetTitle.
  ///
  /// In en, this message translates to:
  /// **'Link'**
  String get linkSheetTitle;

  /// No description provided for @linkSheetHint.
  ///
  /// In en, this message translates to:
  /// **'Address, e.g. https://…'**
  String get linkSheetHint;

  /// No description provided for @linkSheetBad.
  ///
  /// In en, this message translates to:
  /// **'That doesn\'t look like an address'**
  String get linkSheetBad;

  /// No description provided for @linkSheetDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get linkSheetDone;

  /// No description provided for @linkSheetRemove.
  ///
  /// In en, this message translates to:
  /// **'Remove link'**
  String get linkSheetRemove;

  /// No description provided for @linkHiddenWarning.
  ///
  /// In en, this message translates to:
  /// **'The link text and its address differ — check where it leads'**
  String get linkHiddenWarning;

  /// No description provided for @codeCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get codeCopy;

  /// No description provided for @codeCopied.
  ///
  /// In en, this message translates to:
  /// **'Code copied'**
  String get codeCopied;

  /// No description provided for @a11ySpoiler.
  ///
  /// In en, this message translates to:
  /// **'Hidden text, double-tap to show'**
  String get a11ySpoiler;

  /// No description provided for @a11yQuote.
  ///
  /// In en, this message translates to:
  /// **'Quote'**
  String get a11yQuote;

  /// No description provided for @a11yCodeBlock.
  ///
  /// In en, this message translates to:
  /// **'Code'**
  String get a11yCodeBlock;

  /// No description provided for @callBarIncoming.
  ///
  /// In en, this message translates to:
  /// **'Incoming call'**
  String get callBarIncoming;

  /// No description provided for @callBarEnded.
  ///
  /// In en, this message translates to:
  /// **'Call ended'**
  String get callBarEnded;

  /// No description provided for @profileSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t save the profile — try again'**
  String get profileSaveFailed;

  /// No description provided for @signOutFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t sign out — try again'**
  String get signOutFailed;

  /// No description provided for @startingChat.
  ///
  /// In en, this message translates to:
  /// **'Starting an encrypted chat…'**
  String get startingChat;

  /// No description provided for @restoreFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t sign in — check the connection and try again. The words are still here.'**
  String get restoreFailed;

  /// No description provided for @requestAcceptFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t accept the request — check the connection and try again'**
  String get requestAcceptFailed;

  /// No description provided for @sendQueuedOffline.
  ///
  /// In en, this message translates to:
  /// **'No connection — the message will go out by itself when it\'s back'**
  String get sendQueuedOffline;

  /// No description provided for @safetyNumberA11y.
  ///
  /// In en, this message translates to:
  /// **'Check number: {groups}'**
  String safetyNumberA11y(String groups);

  /// No description provided for @callMicMode.
  ///
  /// In en, this message translates to:
  /// **'Mic: {mode}'**
  String callMicMode(String mode);

  /// No description provided for @callMicStandard.
  ///
  /// In en, this message translates to:
  /// **'Standard'**
  String get callMicStandard;

  /// No description provided for @callMicVoiceIsolation.
  ///
  /// In en, this message translates to:
  /// **'Voice Isolation'**
  String get callMicVoiceIsolation;

  /// No description provided for @callMicWideSpectrum.
  ///
  /// In en, this message translates to:
  /// **'Wide Spectrum'**
  String get callMicWideSpectrum;

  /// No description provided for @callMinimize.
  ///
  /// In en, this message translates to:
  /// **'Minimise — the call goes on'**
  String get callMinimize;

  /// The other person in the call has muted their microphone (under their photo, in the call bar).
  ///
  /// In en, this message translates to:
  /// **'Mic off'**
  String get callPeerMicOff;

  /// No description provided for @callConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting…'**
  String get callConnecting;

  /// No description provided for @callBarReturn.
  ///
  /// In en, this message translates to:
  /// **'tap to return'**
  String get callBarReturn;

  /// No description provided for @callBarAnswer.
  ///
  /// In en, this message translates to:
  /// **'tap to answer'**
  String get callBarAnswer;

  /// No description provided for @myProfileTitle.
  ///
  /// In en, this message translates to:
  /// **'My profile'**
  String get myProfileTitle;

  /// No description provided for @myProfileShare.
  ///
  /// In en, this message translates to:
  /// **'Share so people can message me'**
  String get myProfileShare;

  /// No description provided for @myProfileQrHint.
  ///
  /// In en, this message translates to:
  /// **'Show this code — scanning it lets people message you. It isn’t a password: there’s nothing secret in it.'**
  String get myProfileQrHint;

  /// No description provided for @myProfileAddress.
  ///
  /// In en, this message translates to:
  /// **'Your Sinhron address'**
  String get myProfileAddress;

  /// No description provided for @myProfileNotReady.
  ///
  /// In en, this message translates to:
  /// **'Your address appears once the phone connects to the server.'**
  String get myProfileNotReady;

  /// No description provided for @myProfileNoBio.
  ///
  /// In en, this message translates to:
  /// **'A few words about you — tap Edit'**
  String get myProfileNoBio;

  /// No description provided for @settingsProfileHint.
  ///
  /// In en, this message translates to:
  /// **'Profile and QR code so people can message you'**
  String get settingsProfileHint;

  /// No description provided for @settingsNotificationsHint.
  ///
  /// In en, this message translates to:
  /// **'Sound, vibration and what a notification shows'**
  String get settingsNotificationsHint;

  /// No description provided for @settingsPrivacyHint.
  ///
  /// In en, this message translates to:
  /// **'Who sees you online and your read ticks'**
  String get settingsPrivacyHint;

  /// No description provided for @settingsAppLockHint.
  ///
  /// In en, this message translates to:
  /// **'Ask for Face ID or a passcode on opening'**
  String get settingsAppLockHint;

  /// No description provided for @settingsAppLockHintAndroid.
  ///
  /// In en, this message translates to:
  /// **'Ask for a fingerprint or screen lock on opening'**
  String get settingsAppLockHintAndroid;

  /// No description provided for @settingsAppearanceHint.
  ///
  /// In en, this message translates to:
  /// **'Theme, colour and wallpaper'**
  String get settingsAppearanceHint;

  /// No description provided for @settingsChatsSection.
  ///
  /// In en, this message translates to:
  /// **'Chats & folders'**
  String get settingsChatsSection;

  /// No description provided for @settingsNewFolderHint.
  ///
  /// In en, this message translates to:
  /// **'For example Work or Family'**
  String get settingsNewFolderHint;

  /// No description provided for @settingsArchiveHint.
  ///
  /// In en, this message translates to:
  /// **'Chats you moved out of the list'**
  String get settingsArchiveHint;

  /// No description provided for @settingsStorageHint.
  ///
  /// In en, this message translates to:
  /// **'How much space photos and videos take'**
  String get settingsStorageHint;

  /// No description provided for @settingsAccountSection.
  ///
  /// In en, this message translates to:
  /// **'Account & devices'**
  String get settingsAccountSection;

  /// No description provided for @settingsDevicesHint.
  ///
  /// In en, this message translates to:
  /// **'Phones and computers with your account'**
  String get settingsDevicesHint;

  /// No description provided for @settingsWordsHint.
  ///
  /// In en, this message translates to:
  /// **'Bring your account back on a new phone'**
  String get settingsWordsHint;

  /// No description provided for @settingsAdvanced.
  ///
  /// In en, this message translates to:
  /// **'Advanced'**
  String get settingsAdvanced;

  /// No description provided for @settingsProxyHint.
  ///
  /// In en, this message translates to:
  /// **'Hide your phone’s IP from the server; backup route for calls'**
  String get settingsProxyHint;

  /// No description provided for @settingsHelpHint.
  ///
  /// In en, this message translates to:
  /// **'Questions, problems, reports'**
  String get settingsHelpHint;

  /// No description provided for @transferOutTitle.
  ///
  /// In en, this message translates to:
  /// **'Moving everything to your new device'**
  String get transferOutTitle;

  /// No description provided for @transferInTitle.
  ///
  /// In en, this message translates to:
  /// **'Bringing everything over from your other device'**
  String get transferInTitle;

  /// No description provided for @transferStageBuild.
  ///
  /// In en, this message translates to:
  /// **'Packing chats, contacts and settings…'**
  String get transferStageBuild;

  /// No description provided for @transferStageUpload.
  ///
  /// In en, this message translates to:
  /// **'Sending: {done} of {total}'**
  String transferStageUpload(int done, int total);

  /// No description provided for @transferStageOffer.
  ///
  /// In en, this message translates to:
  /// **'Telling your new device…'**
  String get transferStageOffer;

  /// No description provided for @transferStageMedia.
  ///
  /// In en, this message translates to:
  /// **'Photos and files: {done} of {total}'**
  String transferStageMedia(int done, int total);

  /// No description provided for @transferStageManifest.
  ///
  /// In en, this message translates to:
  /// **'Getting ready…'**
  String get transferStageManifest;

  /// No description provided for @transferStageParts.
  ///
  /// In en, this message translates to:
  /// **'Receiving chats: {done} of {total}'**
  String transferStageParts(int done, int total);

  /// No description provided for @transferStagePacks.
  ///
  /// In en, this message translates to:
  /// **'Loading sticker packs…'**
  String get transferStagePacks;

  /// No description provided for @transferDone.
  ///
  /// In en, this message translates to:
  /// **'Done — {messages} messages moved'**
  String transferDone(int messages);

  /// No description provided for @transferDoneMediaLater.
  ///
  /// In en, this message translates to:
  /// **'{messages} messages are here. Photos and files open as your other device puts them up'**
  String transferDoneMediaLater(int messages);

  /// No description provided for @transferDoneMissing.
  ///
  /// In en, this message translates to:
  /// **'Done — {messages} messages. {missing} photos and files were no longer anywhere'**
  String transferDoneMissing(int messages, int missing);

  /// No description provided for @transferFailed.
  ///
  /// In en, this message translates to:
  /// **'The transfer didn\'t finish. On your other device: Devices → this device → Send everything'**
  String get transferFailed;

  /// No description provided for @transferWaiting.
  ///
  /// In en, this message translates to:
  /// **'No connection — it carries on when you\'re back online'**
  String get transferWaiting;

  /// No description provided for @transferHide.
  ///
  /// In en, this message translates to:
  /// **'Hide'**
  String get transferHide;

  /// No description provided for @transferStop.
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get transferStop;

  /// No description provided for @transferStrip.
  ///
  /// In en, this message translates to:
  /// **'Bringing your chats over… {percent}%'**
  String transferStrip(int percent);

  /// No description provided for @devicesSendAll.
  ///
  /// In en, this message translates to:
  /// **'Send everything to this device'**
  String get devicesSendAll;

  /// No description provided for @devicesSendAllFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t start the transfer. Check the connection and try again.'**
  String get devicesSendAllFailed;

  /// No description provided for @devicesSyncNote.
  ///
  /// In en, this message translates to:
  /// **'Your devices stay in step: chats with their whole history, contacts, blocked people, sticker packs, folders and privacy settings. Look, sounds and connection settings stay per device.'**
  String get devicesSyncNote;

  /// No description provided for @serverChatTitle.
  ///
  /// In en, this message translates to:
  /// **'Server'**
  String get serverChatTitle;

  /// No description provided for @serverChatSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Service notices · for the administrator'**
  String get serverChatSubtitle;

  /// No description provided for @serverChatEmpty.
  ///
  /// In en, this message translates to:
  /// **'All quiet — no notices yet.'**
  String get serverChatEmpty;

  /// No description provided for @serverChatFooter.
  ///
  /// In en, this message translates to:
  /// **'Your server writes here because you are its administrator. You can\'t reply. Notices are kept on the server for 30 days. Long press — copy.'**
  String get serverChatFooter;

  /// No description provided for @previewReply.
  ///
  /// In en, this message translates to:
  /// **'So jealous! Take me with you next time? 😍'**
  String get previewReply;

  /// No description provided for @previewSure.
  ///
  /// In en, this message translates to:
  /// **'Of course! 🙌'**
  String get previewSure;

  /// No description provided for @wallSameAsAll.
  ///
  /// In en, this message translates to:
  /// **'Same as all chats'**
  String get wallSameAsAll;

  /// Profile / chat info row: send this person's contact card into a chat
  ///
  /// In en, this message translates to:
  /// **'Share contact'**
  String get shareContact;

  /// Chat picker title when sharing a contact
  ///
  /// In en, this message translates to:
  /// **'Send contact to…'**
  String get shareContactTo;

  /// Confirmation after a contact card was sent
  ///
  /// In en, this message translates to:
  /// **'Contact sent'**
  String get contactSent;

  /// Contact card in a chat: the person shared no name
  ///
  /// In en, this message translates to:
  /// **'Contact'**
  String get contactCardNoName;

  /// Contact card in a chat from someone not yet known: the name is what the sender typed
  ///
  /// In en, this message translates to:
  /// **'Name from the card, not checked'**
  String get contactCardNameUnverified;

  /// Chat list preview of a contact card
  ///
  /// In en, this message translates to:
  /// **'Contact: {name}'**
  String contactCardPreview(String name);
}

class _AppL10nDelegate extends LocalizationsDelegate<AppL10n> {
  const _AppL10nDelegate();

  @override
  Future<AppL10n> load(Locale locale) {
    return SynchronousFuture<AppL10n>(lookupAppL10n(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'ru'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppL10nDelegate old) => false;
}

AppL10n lookupAppL10n(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppL10nEn();
    case 'ru':
      return AppL10nRu();
  }

  throw FlutterError(
    'AppL10n.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
