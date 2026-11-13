// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_l10n.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppL10nEn extends AppL10n {
  AppL10nEn([String locale = 'en']) : super(locale);

  @override
  String get chatsTitle => 'Chats';

  @override
  String get tabChats => 'Chats';

  @override
  String get tabCalls => 'Calls';

  @override
  String get tabContacts => 'Contacts';

  @override
  String get tabSettings => 'Settings';

  @override
  String get folderAll => 'All';

  @override
  String get folderPersonal => 'Personal';

  @override
  String get folderGroups => 'Groups';

  @override
  String get folderUnread => 'Unread';

  @override
  String get cancel => 'Cancel';

  @override
  String get mute => 'Mute';

  @override
  String get archive => 'Archive';

  @override
  String get pin => 'Pin';

  @override
  String get markUnread => 'Mark as unread';

  @override
  String get editFolder => 'Edit folder';

  @override
  String get moveLeft => 'Move left';

  @override
  String get moveRight => 'Move right';

  @override
  String get markAllRead => 'Mark all as read';

  @override
  String get deleteFolder => 'Delete folder';

  @override
  String get chatsLoadError => 'Chats could not be loaded';

  @override
  String get pullToRetry => 'Pull down to try again.';

  @override
  String get noChatsYet => 'No chats yet';

  @override
  String get noChatsHint => 'Tap the pencil at the top to message someone.';

  @override
  String get noChatsHere => 'No chats here';

  @override
  String folderEmptyHint(String name) {
    return 'Chats matching “$name” will show up here.';
  }

  @override
  String get archivedChats => 'Archived chats';

  @override
  String get unmute => 'Unmute';

  @override
  String get unarchive => 'Unarchive';

  @override
  String get delete => 'Delete';

  @override
  String get open => 'Open';

  @override
  String get unpin => 'Unpin';

  @override
  String get moveUp => 'Move up';

  @override
  String get moveDown => 'Move down';

  @override
  String get markRead => 'Mark as read';

  @override
  String get deleteChat => 'Delete chat';

  @override
  String deleteChatConfirm(String name) {
    return 'Delete the chat with $name? Messages on this device are removed for good.';
  }

  @override
  String get noMessagesYet => 'No messages yet';

  @override
  String deleteFolderConfirm(String name) {
    return 'Delete the folder “$name”? Chats stay where they are.';
  }

  @override
  String get newFolder => 'New folder';

  @override
  String get save => 'Save';

  @override
  String get folderName => 'Folder name';

  @override
  String get include => 'Include';

  @override
  String get allPersonal => 'All personal chats';

  @override
  String get allGroups => 'All groups';

  @override
  String get hide => 'Hide';

  @override
  String get archivedNotInFolders => 'Archived chats never show in folders.';

  @override
  String get mutedChats => 'Muted chats';

  @override
  String get readChats => 'Read chats';

  @override
  String chatsInFolderCount(int n) {
    return 'Chats · $n in folder';
  }

  @override
  String get folderChatHint =>
      'Tap a chat to always include it, tap again to always hide it.';

  @override
  String get included => 'Included';

  @override
  String get hidden => 'Hidden';

  @override
  String get byRule => 'By rule';

  @override
  String get noArchivedChats => 'No archived chats';

  @override
  String get archiveHint =>
      'Swipe a chat left and tap Archive to tuck it away here.';

  @override
  String get searchHint => 'Search messages, chats, media…';

  @override
  String get searchRecent => 'Recent';

  @override
  String get searchRecentClear => 'Clear';

  @override
  String searchRecentRemove(String name) {
    return 'Remove $name from recent';
  }

  @override
  String get searchEmptyTitle => 'Search chats and messages';

  @override
  String get searchPrivacy =>
      'Search runs only on this device — your server never sees what you\'re looking for.';

  @override
  String get messagesSection => 'Messages';

  @override
  String groupWithTime(String time) {
    return 'Group · $time';
  }

  @override
  String noResults(String query) {
    return 'No results for “$query”';
  }

  @override
  String get noResultsHint =>
      'Try a shorter word or a different spelling. Search only looks at messages stored on this device.';

  @override
  String get openLink => 'Open link';

  @override
  String get errLibrary => 'Photo library unavailable';

  @override
  String get messageDeleted => 'This message was deleted';

  @override
  String get replyToYourself => 'Reply to yourself';

  @override
  String replyTo(String name) {
    return 'Reply to $name';
  }

  @override
  String get statusFailed => 'Not sent';

  @override
  String get messageNotSent => 'Not sent · Tap to retry';

  @override
  String get retrySend => 'Retry';

  @override
  String get msgInfo => 'Info';

  @override
  String get msgInfoSent => 'Sent';

  @override
  String get msgInfoDelivered => 'Delivered';

  @override
  String get msgInfoRead => 'Read';

  @override
  String get msgInfoNotYet => 'Not delivered yet';

  @override
  String get statusSending => 'Sending';

  @override
  String get statusSent => 'Sent';

  @override
  String get statusDelivered => 'Delivered';

  @override
  String get kindVoice => 'Voice message';

  @override
  String timerMinutes(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: '$n minutes',
      one: '1 minute',
    );
    return '$_temp0';
  }

  @override
  String timerHours(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: '$n hours',
      one: '1 hour',
    );
    return '$_temp0';
  }

  @override
  String timerDays(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: '$n days',
      one: '1 day',
    );
    return '$_temp0';
  }

  @override
  String timerWeeks(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: '$n weeks',
      one: '1 week',
    );
    return '$_temp0';
  }

  @override
  String get couldNotEdit => 'Could not edit the message';

  @override
  String get reply => 'Reply';

  @override
  String get copy => 'Copy';

  @override
  String get forward => 'Forward';

  @override
  String get savedMessages => 'Saved Messages';

  @override
  String get savedMessagesHint =>
      'Notes, links and files — on all your devices';

  @override
  String get saveToSaved => 'Save';

  @override
  String get savedToSaved => 'Saved to Saved Messages';

  @override
  String get savedMessagesFailed =>
      'Couldn’t open Saved Messages — check the connection and try again';

  @override
  String get edit => 'Edit';

  @override
  String get select => 'Select';

  @override
  String get selectText => 'Select text';

  @override
  String get copyAll => 'Copy all';

  @override
  String get selectTextClose => 'Close';

  @override
  String deleteMessagesConfirm(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: 'Delete $n messages?',
      one: 'Delete this message?',
    );
    return '$_temp0';
  }

  @override
  String get deleteForEveryone => 'Delete for everyone';

  @override
  String get deleteForMe => 'Delete for me';

  @override
  String get call => 'Call';

  @override
  String get timerSheetTitle =>
      'Disappearing messages — new messages in this chat delete themselves on both phones after:';

  @override
  String get timerOff => 'Off';

  @override
  String get errNotEncrypted =>
      'This chat isn’t encrypted, so nothing can be sent from it';

  @override
  String get errTooLarge => 'File is too large (max 95 MB)';

  @override
  String get errOffline => 'Not connected to the server';

  @override
  String get errCouldNotSend =>
      'Couldn’t send. Check the connection and try again.';

  @override
  String get errCamera => 'Camera unavailable or access denied';

  @override
  String get errFiles => 'Couldn’t open Files. Try again.';

  @override
  String get errMic => 'Microphone access denied';

  @override
  String get pinnedMessage => 'Pinned message';

  @override
  String get quoteFallback => 'Reply';

  @override
  String get you => 'You';

  @override
  String get chatEmptyHint =>
      'Say hi 👋 — only the two of you can read this chat.';

  @override
  String get errLoadMessages =>
      'Couldn’t load the messages. Close the chat and open it again.';

  @override
  String get typing => 'typing…';

  @override
  String get safetyChanged => 'check number changed';

  @override
  String get online => 'online';

  @override
  String get youDeleted => 'You deleted this message';

  @override
  String get edited => 'edited';

  @override
  String get messagePlaceholder => 'Message';

  @override
  String get camera => 'Camera';

  @override
  String get photos => 'Photos';

  @override
  String get video => 'Video';

  @override
  String get document => 'Document';

  @override
  String get slideToCancel => '‹ Slide to cancel   ↑ lock';

  @override
  String get unreadMessages => 'Unread messages';

  @override
  String get editMessage => 'Edit message';

  @override
  String selectedCount(int n) {
    return '$n selected';
  }

  @override
  String get statusRead => 'Read';

  @override
  String get editedA11y => ', edited';

  @override
  String get kindPhoto => 'Photo';

  @override
  String get timerOffByMe => 'You turned off disappearing messages';

  @override
  String get timerOffByPeer => 'Disappearing messages turned off';

  @override
  String timerSetByMe(String time) {
    return 'You set messages to disappear after $time';
  }

  @override
  String timerSetByPeer(String time) {
    return 'Messages now disappear after $time';
  }

  @override
  String get timeNow => 'now';

  @override
  String get yesterday => 'Yesterday';

  @override
  String get today => 'Today';

  @override
  String get couldNotShare => 'Could not share';

  @override
  String get showQr => 'Show a QR code instead';

  @override
  String verifiedBody(String name) {
    return 'You checked that this is really $name.';
  }

  @override
  String safetyChangedBody(String name) {
    return '$name’s check number changed — most likely a new phone. Check again.';
  }

  @override
  String get notVerifiedBody =>
      'Messages are encrypted either way. Checking makes sure nobody is secretly in between.';

  @override
  String get neverShown => 'Never shown';

  @override
  String get perChat => 'Per chat';

  @override
  String get off => 'Off';

  @override
  String get previewOut => 'Great! We just got back from the mountains 🏔';

  @override
  String get forwardTo => 'Forward to…';

  @override
  String get noOtherChats => 'No other chats';

  @override
  String get shareSendTo => 'Send to…';

  @override
  String get shareSearch => 'Search chats';

  @override
  String get shareCaptionHint => 'Add a caption…';

  @override
  String get shareMessageHint => 'Message';

  @override
  String get sharePickChat => 'Choose a chat';

  @override
  String get shareSend => 'Send';

  @override
  String shareSendCount(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: 'Send to $n chats',
      one: 'Send to 1 chat',
    );
    return '$_temp0';
  }

  @override
  String sharePhotos(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: '$n photos',
      one: 'Photo',
    );
    return '$_temp0';
  }

  @override
  String shareVideos(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: '$n videos',
      one: 'Video',
    );
    return '$_temp0';
  }

  @override
  String shareFiles(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: '$n files',
      one: '1 file',
    );
    return '$_temp0';
  }

  @override
  String get shareSent => 'Sent';

  @override
  String get shareNoChats => 'No chats yet — start one first';

  @override
  String get shareNoAccount => 'Sign in to Sinhron first, then share again.';

  @override
  String get shareNothing =>
      'Nothing to send: that app shared nothing Sinhron can open.';

  @override
  String get videoUnavailable => 'Video unavailable';

  @override
  String get videoPlay => 'Play';

  @override
  String get videoPause => 'Pause';

  @override
  String get videoSoundOn => 'Sound on';

  @override
  String get videoSoundOff => 'Sound off';

  @override
  String get viewerClose => 'Close';

  @override
  String get showInChat => 'Show in chat';

  @override
  String get forwarded => 'Forwarded';

  @override
  String get couldNotForward => 'Could not forward';

  @override
  String get decrypting => 'Opening…';

  @override
  String nOfM(int n, int m) {
    return '$n of $m';
  }

  @override
  String get share => 'Share';

  @override
  String get shared => 'Shared';

  @override
  String get saveToPhotos => 'Save';

  @override
  String get savedToPhotos => 'Saved to Photos';

  @override
  String get couldNotSave => 'Could not save';

  @override
  String get quickCheck => 'Quick check';

  @override
  String quickCheckBody(int n, int m) {
    return 'Just to be sure the words are safe on paper. $n of $m.';
  }

  @override
  String whichWord(int n) {
    return 'Which is word #$n?';
  }

  @override
  String wrongWord(int n) {
    return 'Not quite — have another look at word #$n on your paper.';
  }

  @override
  String get showWordsAgain => 'Show me the words again';

  @override
  String get saveAccessTitle => 'Keep access to your account';

  @override
  String get saveAccessBody =>
      'Your account is 24 secret words. If this phone is lost, they bring the account back on a new one. We don’t have them — keep them where you won’t lose them.';

  @override
  String get saveToPasswordsIos => 'Save to iCloud Keychain';

  @override
  String get saveToPasswordsAndroid => 'Save to password manager';

  @override
  String get savePasswordsHintIos =>
      'One tap. Only Sinhron can read them — they aren’t in the Passwords app, and no website can ask for them. With iCloud Keychain on, they come to your new iPhone.';

  @override
  String get savePasswordsHintAndroid =>
      'One tap. Google encrypts them and brings them to your new phone with your Google account.';

  @override
  String get passwordsFailed =>
      'Couldn’t save to the password manager. Try again or write the words down.';

  @override
  String get writeWordsAction => 'Write the words down';

  @override
  String get writeWordsRowHint => 'On paper, or a sheet to print';

  @override
  String get saveLater => 'Later';

  @override
  String get saveLaterHint =>
      'Until then the words are only on this phone. We’ll remind you in Settings.';

  @override
  String get writeWordsTitle => 'Write down the 24 words';

  @override
  String get writeWordsBody =>
      'In this order, on paper. Keep it like a passport: anyone who reads these words can open your account.';

  @override
  String get screenshotNote =>
      'A screenshot isn’t a safe place: it goes to the cloud with your photos.';

  @override
  String get wordsWritten => 'I’ve written them down';

  @override
  String get sheetAction => 'Recovery sheet to print';

  @override
  String get sheetTitle => 'Sinhron — secret words';

  @override
  String get sheetHowTitle => 'How to get your account back';

  @override
  String get sheetHowBody =>
      'Install Sinhron on the new phone → “Sign in with secret words” → scan this code or type the 24 words in order.';

  @override
  String get sheetWarning =>
      'Anyone who sees these words owns your account. Print this sheet and delete the file. Don’t send it to anyone and don’t keep a photo of it in the cloud.';

  @override
  String get sheetScan => 'Scan the recovery sheet';

  @override
  String get sheetNotWords => 'This code isn’t a recovery sheet.';

  @override
  String get pasteFromPasswordsIos => 'Paste from iCloud Keychain';

  @override
  String get pasteFromPasswordsAndroid => 'Paste from password manager';

  @override
  String get reminderBody =>
      'Your secret words are only on this phone. Save them so you don’t lose the account.';

  @override
  String get reminderSave => 'Save';

  @override
  String get wordsNotSaved => 'Not saved';

  @override
  String get accessNotSavedTitle => 'Access not saved';

  @override
  String get accessNotSavedBody =>
      'The words are only on this phone. If something happens to it, the account can’t be brought back.';

  @override
  String get accessSaveSection => 'Save';

  @override
  String get accessSaveFooter =>
      'Once saved, the words leave this phone — they’ll be where you saved them.';

  @override
  String get accessSavedTitle => 'Access saved';

  @override
  String accessSavedPasswordsIos(String date) {
    return 'In Passwords · $date, as a website password — a website could ask for it. Move them below.';
  }

  @override
  String accessSavedKeychainIos(String date) {
    return 'In iCloud Keychain · $date. Only Sinhron reads them; they move to a new iPhone with iCloud Keychain on.';
  }

  @override
  String get moveToKeychain => 'Move to iCloud Keychain';

  @override
  String get moveToKeychainFooter =>
      'Pick the Sinhron entry: the words move to iCloud Keychain, and the old Passwords entry is deleted.';

  @override
  String accessSavedPasswordsAndroid(String date) {
    return 'In the password manager · $date. They come to a new phone with your Google account.';
  }

  @override
  String accessSavedPaper(String date) {
    return 'Written down · $date. Keep the paper like a passport.';
  }

  @override
  String accessSavedSheet(String date) {
    return 'Recovery sheet · $date. Print it and delete the file.';
  }

  @override
  String accessSavedChecked(String date) {
    return 'Checked · $date. You have the right words.';
  }

  @override
  String get accessSavedDone => 'Saved';

  @override
  String get phraseStatusAllWords => '24 words';

  @override
  String get secondDeviceSection => 'Second device';

  @override
  String secondDeviceCount(int n) {
    return 'Other devices: $n';
  }

  @override
  String get secondDeviceLink => 'Link a second device';

  @override
  String get secondDeviceYes =>
      'If something happens to this phone, your chats stay on your other device. But a new phone can still be added only with the secret words.';

  @override
  String get secondDeviceNo =>
      'A second device (a tablet, another phone) keeps your chats if this phone is lost. It doesn’t replace the words: a new phone is added with them.';

  @override
  String get checkWordsTitle => 'Check the words';

  @override
  String get checkWordsBody =>
      'Enter your 24 secret words — the app compares them with this account. They aren’t stored.';

  @override
  String get checkWordsAction => 'Check';

  @override
  String get wordsMatch => 'Right — these are your words';

  @override
  String get wordsDontMatch => 'These aren’t this account’s words';

  @override
  String verifyTitle(String name) {
    return 'Check $name';
  }

  @override
  String get verifyNotYet =>
      'This chat can’t be verified yet — send a message first.';

  @override
  String get showNumber => 'Show the number instead';

  @override
  String verifyExplain(String name) {
    return 'Compare this number with the one on $name’s phone — in person or on a call. If they match, nobody is in between and only you two read the chat.';
  }

  @override
  String get clearVerification => 'Clear verification';

  @override
  String get markVerified => 'Mark as verified';

  @override
  String get verifiedTitle => 'Verified';

  @override
  String get safetyChangedTitle => 'Check number changed';

  @override
  String get notVerifiedTitle => 'Not verified yet';

  @override
  String get unlockReason => 'Unlock Sinhron';

  @override
  String get appLocked => 'Sinhron is locked';

  @override
  String get tapToUnlock => 'Tap to unlock with Face ID or your passcode';

  @override
  String get setPasscodeFirst =>
      'Set a passcode on this iPhone first — App Lock uses it.';

  @override
  String get turnOnAppLock => 'Turn on App Lock';

  @override
  String get lockAgain => 'Lock again';

  @override
  String get appLockTitle => 'App lock';

  @override
  String get lockSection => 'Lock';

  @override
  String get appLockFooter =>
      'When on, Sinhron asks for Face ID or your iPhone passcode when it opens. Your chats stay encrypted either way.';

  @override
  String get appLockToggle => 'App Lock';

  @override
  String get appSwitcher => 'App switcher';

  @override
  String get appSwitcherFooter =>
      'Covers your chats with a blur when you switch apps, so they don’t show in the app switcher.';

  @override
  String get hideInSwitcher => 'Hide chats in app switcher';

  @override
  String get privacyTitle => 'Privacy & security';

  @override
  String get whatOthersSee => 'What others see';

  @override
  String get whatOthersSeeFooter =>
      'Turning off read ticks or typing also hides them from you — fair both ways. “Online” and “last seen” go only to your contacts — people you have a personal chat with — and only while this is on. Turning it off makes them forget when they last saw you.';

  @override
  String get readReceipts => 'Read ticks';

  @override
  String get typingIndicators => 'Typing indicators';

  @override
  String get onlineStatus => 'Online status';

  @override
  String get showOnline => 'Show when I’m online';

  @override
  String get onlyContacts => 'Contacts only';

  @override
  String get lastSeenJustNow => 'last seen just now';

  @override
  String lastSeenMinutes(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: 'last seen $n minutes ago',
      one: 'last seen 1 minute ago',
    );
    return '$_temp0';
  }

  @override
  String lastSeenToday(String time) {
    return 'last seen today at $time';
  }

  @override
  String lastSeenYesterday(String time) {
    return 'last seen yesterday at $time';
  }

  @override
  String lastSeenDate(String date) {
    return 'last seen $date';
  }

  @override
  String get disappearingMessages => 'Disappearing messages';

  @override
  String get disappearingFooter =>
      'Set it per chat: press and hold the chat’s name at the top. Messages then delete themselves on both phones — text and photos alike.';

  @override
  String get timer => 'Timer';

  @override
  String get links => 'Links';

  @override
  String get linksFooter =>
      'Your phone fetches the link’s picture and title when you send it: the site learns it was opened from your phone, never who you’re writing to. Off by default.';

  @override
  String get linkPreviews => 'Link previews';

  @override
  String get thisDevice => 'This device';

  @override
  String get on => 'On';

  @override
  String get e2eTitle => 'Encrypted';

  @override
  String get e2eAlways => 'Always on. Not a setting.';

  @override
  String get e2eBody =>
      'Your messages, calls and files can be read only on your devices and the people you send them to. Your server sees encrypted data and delivery timing — never content, never who you talk to.';

  @override
  String get chipKeys => 'Every message has its own key';

  @override
  String get chipOld => 'Old messages stay safe';

  @override
  String get chipHeal => 'Protection recovers by itself after a break-in';

  @override
  String get appearance => 'Appearance';

  @override
  String get theme => 'Theme';

  @override
  String get accentColour => 'Accent colour';

  @override
  String get chatWallpaper => 'Chat wallpaper';

  @override
  String get wallpaperFooter => 'Your own photo stays on this device only.';

  @override
  String get previewIn => 'Hi! How are you? 👋';

  @override
  String get unavailable => 'Unavailable';

  @override
  String get file => 'File';

  @override
  String get documentUnavailable => 'Document unavailable';

  @override
  String get couldNotOpen => 'Could not open — tap to retry';

  @override
  String get photoUnavailable => 'Photo unavailable';

  @override
  String get whatPhoto => 'photo';

  @override
  String get whatVoice => 'voice message';

  @override
  String get whatVideo => 'video';

  @override
  String notSentRetry(String what) {
    return 'Not sent: $what — tap to retry';
  }

  @override
  String sendingPercent(String what, int p) {
    return 'Sending $what… $p%';
  }

  @override
  String preparing(String what) {
    return 'Preparing $what…';
  }

  @override
  String sending(String what) {
    return 'Sending $what…';
  }

  @override
  String get lockImmediately => 'Immediately';

  @override
  String lockAfterMinutes(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: 'After $n minutes',
      one: 'After 1 minute',
    );
    return '$_temp0';
  }

  @override
  String get lockAfterHour => 'After 1 hour';

  @override
  String get themeSystem => 'System';

  @override
  String get themeLight => 'Light';

  @override
  String get themeDark => 'Dark';

  @override
  String get themeOled => 'Black (OLED)';

  @override
  String get wallNone => 'None';

  @override
  String get wallDawn => 'Dawn';

  @override
  String get wallMist => 'Mist';

  @override
  String get wallDusk => 'Dusk';

  @override
  String get wallDots => 'Dots';

  @override
  String get wallWaves => 'Waves';

  @override
  String get wallPhoto => 'Photo';

  @override
  String get yourName => 'Your name';

  @override
  String get keyNotCreated => 'Address not ready yet';

  @override
  String keyFingerprint(String fp) {
    return 'Address $fp';
  }

  @override
  String get language => 'Language';

  @override
  String get langSystem => 'As on phone';

  @override
  String get langEn => 'English';

  @override
  String get langRu => 'Русский';

  @override
  String get privacySection => 'Privacy';

  @override
  String get privacySectionFooter =>
      'Your chats are always encrypted — only you and the people in them can read them. These options control what other people and your server can see about you.';

  @override
  String get review => 'Review';

  @override
  String get linkedDevices => 'Devices';

  @override
  String get accountKey => 'Secret words';

  @override
  String get notifications => 'Notifications';

  @override
  String get notificationsFooter =>
      'When Sinhron is closed, an iPhone shows only “New message” — your server can’t read messages.';

  @override
  String get soundsVibration => 'Sounds & vibrations';

  @override
  String get textSize => 'Text size';

  @override
  String get asInIphone => 'As in iPhone settings';

  @override
  String get wallpaper => 'Wallpaper';

  @override
  String get storage => 'Storage';

  @override
  String get server => 'Server';

  @override
  String get serverFooter =>
      'The server is the computer that carries your messages to other people. Its owner can see when messages are delivered, never what’s inside them.';

  @override
  String get notConnected => 'Not connected';

  @override
  String get about => 'About';

  @override
  String updateAvailableTitle(String version) {
    return 'Update $version is available';
  }

  @override
  String get updateAvailableBody =>
      'It downloads right here; then Android asks you to tap Install. Chats and keys stay.';

  @override
  String get updateAction => 'Update';

  @override
  String updateDownloading(int percent) {
    return 'Downloading the update… $percent%';
  }

  @override
  String get updateReadyTitle => 'The update is downloaded';

  @override
  String get updateReadyBody => 'Tap Install — Android will ask once more.';

  @override
  String get updateInstall => 'Install';

  @override
  String get updateFailedOffline =>
      'Couldn\'t download the update. Check the internet and try again.';

  @override
  String get updateFailedBadFile =>
      'The update file didn\'t pass the safety check, so it won\'t be installed. Try again later.';

  @override
  String get updateFailedInstaller =>
      'Android didn\'t open the installer. Try again.';

  @override
  String get updateRetry => 'Try again';

  @override
  String get updateLater => 'Later';

  @override
  String get updateCheck => 'Check for updates';

  @override
  String get updateCheckHint => 'New versions come from our server';

  @override
  String get updateChecking => 'Checking…';

  @override
  String get updateUpToDate => 'You have the latest version';

  @override
  String get updateOffline => 'No connection to the server — try later';

  @override
  String updateNewVersion(String version) {
    return '$version available';
  }

  @override
  String get updatePermissionExplain =>
      'Android will now ask whether Sinhron may install apps. Tap Settings, turn on “Allow from this source” and go back — the installation carries on; then tap Install. It asks only the first time.';

  @override
  String get updateContinue => 'Continue';

  @override
  String get clipboardClears => 'Clipboard auto-clears 60s after copy';

  @override
  String get copied => 'Copied';

  @override
  String get copyPhrase => 'Copy the words';

  @override
  String get tagline => 'Messages that stay between you.';

  @override
  String get getStarted => 'Get started';

  @override
  String get linkDevice => 'Link a device';

  @override
  String get restoreFromKey => 'Sign in with secret words →';

  @override
  String get pickServer => 'Pick a server';

  @override
  String get pickServerBody =>
      'A server is the computer that carries your messages to other people. Your team’s, a friend’s or your own will do. It can’t read what you send.';

  @override
  String get serverHowToGet =>
      'Whoever set up the server gives you its address. Type it, or scan the QR code they showed you.';

  @override
  String get serverScanQr => 'Scan server QR code';

  @override
  String get serverInvalid =>
      'That doesn’t look like a server address — for example sinhron.example.com.';

  @override
  String get serverNotSinhron =>
      'Something answered at this address, but it isn’t a Sinhron server.';

  @override
  String get serverUnreachable =>
      'The server isn’t answering. Check the address and your connection.';

  @override
  String get serverNotSaved =>
      'Couldn’t save this on the phone — the app’s storage didn’t open. Close the app and open it again.';

  @override
  String get serverContinueAnyway => 'Continue anyway';

  @override
  String get pairNoServer => 'Choose the server first — go back one step.';

  @override
  String get inviteToken => 'Invite code';

  @override
  String get pasteInvite => 'paste your invite code';

  @override
  String get inviteAuto => 'Filled in automatically from your invite link.';

  @override
  String get continueBtn => 'Continue';

  @override
  String get yourProfile => 'Your profile';

  @override
  String get profileBody =>
      'Name your contacts will see. You can change this any time.';

  @override
  String get nameLabel => 'Name';

  @override
  String get nameHint => 'How you appear to contacts';

  @override
  String get settingUp => 'Setting up your device';

  @override
  String get inApp => 'In the app';

  @override
  String get vibration => 'Vibration';

  @override
  String get inChatSounds => 'In-chat sounds';

  @override
  String get pushNotifications => 'Notifications';

  @override
  String get comingSoon => 'App Store version';

  @override
  String setupConnecting(String host) {
    return 'Connecting to $host';
  }

  @override
  String get setupIdentity => 'Checking this phone';

  @override
  String get setupGroups => 'Joining your groups';

  @override
  String get setupContacts => 'Getting your chats ready';

  @override
  String get mediaLoadError => 'Could not load media';

  @override
  String get noVoiceYet => 'No voice messages yet';

  @override
  String get noLinksYet => 'No links yet';

  @override
  String get sharedMediaMedia => 'Media';

  @override
  String get sharedMediaFiles => 'Files';

  @override
  String get noMediaYet => 'No photos or videos yet';

  @override
  String get noFilesYet => 'No files yet';

  @override
  String get searchContacts => 'Search contacts';

  @override
  String get contactsEmpty =>
      'No contacts yet. Add someone by their QR code, invite link or address — they stay here even if you delete the chat.';

  @override
  String get recent => 'Recent';

  @override
  String get contactsFooter =>
      'Your contacts stay on this phone only — your server can’t see who you talk to. Start a chat with a QR code or an address.';

  @override
  String noContactNamed(String q) {
    return 'No contact named “$q”';
  }

  @override
  String get noContactHint =>
      'Try a different name or invite them with a QR code.';

  @override
  String get newChat => 'New chat';

  @override
  String get newGroup => 'New group';

  @override
  String get inviteByQr => 'Invite by QR';

  @override
  String get scanQr => 'Scan QR';

  @override
  String get pasteKey => 'Paste address';

  @override
  String get pasteFromClipboard => 'Paste';

  @override
  String pasteKeyCount(int count) {
    return '$count of 64 characters';
  }

  @override
  String get pasteKeyReady => 'Address looks right';

  @override
  String get startEncrypted => 'Start encrypted chat';

  @override
  String get pasteKeyHint =>
      'Paste the other person’s address — 64 characters. They find it in My profile → Copy address. They need to be online to get the invite.';

  @override
  String get keyHint => '64 characters';

  @override
  String get sendingInvite => 'Sending invite…';

  @override
  String get startChat => 'Start chat';

  @override
  String get noEmailV => 'we never ask for one';

  @override
  String get skip => 'Skip';

  @override
  String get welcome => 'Welcome';

  @override
  String get privateByDefault => 'Private by default.';

  @override
  String get splash1Body =>
      'Sinhron encrypts everything from the very first message. Your messages, calls and files can be read only on your devices and by the people you send them to.';

  @override
  String get splash2Eyebrow => 'Nothing about you';

  @override
  String get splash2Title => 'No email, no phone, no password.';

  @override
  String get noEmail => 'No email';

  @override
  String get noPhone => 'No phone number';

  @override
  String get noPhoneV => 'people add you by QR code or link';

  @override
  String get noPassword => 'No password';

  @override
  String get noPasswordV => '24 secret words instead';

  @override
  String get ownKey => 'Only you have the words';

  @override
  String get ownKeyV => 'lose the words, lose the account';

  @override
  String get selfHosted => 'Your server';

  @override
  String get serverTrust => 'Sinhron runs on a server you trust.';

  @override
  String get serverRun => 'Your team, your company, or you can run one. ';

  @override
  String get serverData =>
      '. Your data lives there and nowhere else — not with us, not with anyone.';

  @override
  String get a11ySearch => 'Search';

  @override
  String a11yUnread(int n) {
    return '$n unread';
  }

  @override
  String get a11yBack => 'Back';

  @override
  String get a11yVideoCall => 'Video call';

  @override
  String get a11yAttach => 'Attach';

  @override
  String get a11yCloseAttach => 'Close attachments';

  @override
  String get cancelSending => 'Cancel sending';

  @override
  String get splitPickChat => 'Choose a chat';

  @override
  String get splitPickSetting => 'Choose a section';

  @override
  String get splitPickContact => 'Choose a contact';

  @override
  String get splitPickCall => 'Choose a call to open its chat';

  @override
  String get a11yOpenPhoto => 'Open photo';

  @override
  String typingOne(String name) {
    return '$name is typing…';
  }

  @override
  String typingTwo(String a, String b) {
    return '$a and $b are typing…';
  }

  @override
  String typingMany(int count) {
    return '$count people are typing…';
  }

  @override
  String blockedChatNote(String name) {
    return 'You blocked $name: their messages and calls aren\'t shown, and they no longer see your photo or when you\'re online.';
  }

  @override
  String get a11ySend => 'Send';

  @override
  String get a11yRecord =>
      'Hold to record a voice message. Tap to switch to video';

  @override
  String get a11yRecordVideo =>
      'Hold to record a video message. Tap to switch to voice';

  @override
  String get videoMessage => 'Video message';

  @override
  String get videoNoteCropFailed =>
      'Couldn\'t cut the video down to the circle, so it wasn\'t sent. Please record it again.';

  @override
  String get whatVideoNote => 'video message';

  @override
  String get holdToRecordVoice =>
      'Hold to record a voice message, tap for video';

  @override
  String get holdToRecordVideo =>
      'Hold to record a video message, tap for voice';

  @override
  String get errCameraMic =>
      'Allow the camera and microphone in Settings to record video messages';

  @override
  String a11yVideoNotePlay(String duration) {
    return 'Video message, $duration. Tap to play with sound';
  }

  @override
  String get a11yVoiceSeek => 'Playback position. Drag to rewind';

  @override
  String get a11yEmoji => 'Emoji';

  @override
  String a11yMessageFrom(String name, String time) {
    return '$name, $time';
  }

  @override
  String a11yReplyTo(String text) {
    return 'reply to: $text';
  }

  @override
  String a11yReactions(String list) {
    return 'reactions: $list';
  }

  @override
  String get a11yMessageHint => 'Double tap and hold for options';

  @override
  String get a11yPinned => 'pinned';

  @override
  String get a11yMuted => 'muted';

  @override
  String a11yDraft(String text) {
    return 'draft: $text';
  }

  @override
  String get a11yReact => 'React with a heart';

  @override
  String get bannerNewMessage => 'New message';

  @override
  String get notificationReply => 'Reply';

  @override
  String get notificationReplySend => 'Send';

  @override
  String get notificationReplyPlaceholder => 'Message';

  @override
  String get notificationReplyLater =>
      'Your reply will go once Sinhron connects';

  @override
  String get notificationReplyOnOpen =>
      'Your reply will go when you open Sinhron';

  @override
  String get notificationReplyFailed => 'Reply not sent — open the chat';

  @override
  String get notificationNewRequest => 'New message request';

  @override
  String get bannerHint => 'Opens the chat';

  @override
  String get inAppBanners => 'Banners in the app';

  @override
  String get bannerPreview => 'Show message text';

  @override
  String get bannersFooter =>
      'When a message comes into another chat, a banner appears at the top. Tap to open, swipe up to hide. Muted and archived chats stay quiet.';

  @override
  String get iconBadge => 'Unread count on app icon';

  @override
  String get unlockTitle => 'Unlock Sinhron';

  @override
  String get unlockBody =>
      'Your chats on this phone are encrypted. Enter your 24 secret words to open them.';

  @override
  String get reconnectTitle => 'Reconnect your account';

  @override
  String get reconnectBody =>
      'To reach your server again, enter your 24 secret words. You only need to do this once on this phone.';

  @override
  String get unlockHint => '24 words, separated by spaces';

  @override
  String get unlockAction => 'Unlock';

  @override
  String get unlockPhraseNote =>
      'The words never leave the phone and aren’t stored — the phone keeps only a key made from them, in the protected iPhone Keychain.';

  @override
  String get unlockInvalidPhrase =>
      'Those don’t look like your secret words — check the words and their order.';

  @override
  String get unlockWrongPhrase =>
      'These words don’t match the account on this phone.';

  @override
  String get eraseAndStartOver => 'Erase and start over';

  @override
  String get deviceRemovedTitle => 'This device is signed out';

  @override
  String get deviceRemovedBody =>
      'It was disconnected from your account on another of your devices. Chats here no longer update, messages and calls don\'t reach it. Sign out to erase this device\'s copy — your chats stay on your other devices.';

  @override
  String get deviceRemovedAction => 'Sign out';

  @override
  String get eraseConfirmTitle =>
      'All chats on this phone will be deleted. This can\'t be undone.';

  @override
  String get eraseConfirmAction => 'Erase everything';

  @override
  String get netConnected => 'Connected';

  @override
  String get netConnecting => 'Connecting…';

  @override
  String get netOffline => 'Offline';

  @override
  String get reconnect => 'Reconnect';

  @override
  String get connection => 'Connection';

  @override
  String navNewChatName(String id) {
    return 'Chat $id';
  }

  @override
  String get chatDraftPrefix => 'Draft: ';

  @override
  String get phraseStrengthValue => 'Very high';

  @override
  String get photoCouldNotUse =>
      'Couldn’t use this photo. Check access to Photos: phone Settings → Sinhron → Photos.';

  @override
  String get backupSearching => 'Looking for a backup…';

  @override
  String get errRecordingFailed => 'The recording didn’t work — try again';

  @override
  String get linkCouldNotOpen => 'Couldn’t open the link';

  @override
  String get newChatPlaceholder => 'New chat';

  @override
  String get newGroupPlaceholder => 'New group';

  @override
  String get memberUnnamed => 'Member';

  @override
  String get appLockOffNoPasscode =>
      'App Lock is off: this phone has no passcode or Face ID any more. Turn it on again in Settings → App lock.';

  @override
  String get unlockFailed =>
      'Couldn’t open — not because of the words. Try again in a minute.';

  @override
  String get navErrKeyAlreadyInChat =>
      'That address is already in the chat — probably your own. Paste the other person’s address, not yours.';

  @override
  String get navErrNoKeyPackage =>
      'Can’t invite them yet: their phone hasn’t finished setting up. Ask them to open Sinhron and wait until it has loaded, then try again.';

  @override
  String get navErrRateLimited =>
      'Too many requests to the server. Wait a minute and try again.';

  @override
  String get navErrServerUnreachable =>
      'Could not reach the server. Check your internet connection — Sinhron reconnects by itself.';

  @override
  String get navErrBadKeyFormat =>
      'An address is exactly 64 characters: digits and the letters a–f. Check that you copied all of it.';

  @override
  String netGroupDefaultName(String id) {
    return 'Group $id';
  }

  @override
  String get netAddedToChat => 'You were added to this chat';

  @override
  String get netUnsupportedMessage =>
      'Unsupported message — update Sinhron to view it';

  @override
  String get chatsEncryptedStarted => 'Encrypted chat started';

  @override
  String get callKitPeerName => 'Sinhron call';

  @override
  String get callErrMic =>
      'No access to the microphone. Allow it in Settings → Sinhron → Microphone.';

  @override
  String get callErrCamera =>
      'No access to the camera. Allow it in Settings → Sinhron → Camera.';

  @override
  String get callErrFailed =>
      'Couldn’t start the call. Check your connection and try again.';

  @override
  String get callsMissed => 'Missed';

  @override
  String get callsEarlier => 'Earlier';

  @override
  String get callsAudio => 'audio';

  @override
  String get callsVideo => 'video';

  @override
  String callsMinutes(int n) {
    return '$n min';
  }

  @override
  String get callsNoAnswer => 'No answer';

  @override
  String get callsDeclined => 'Declined';

  @override
  String get callsEmpty =>
      'No calls yet. Start one from a chat — the phone button at the top.';

  @override
  String get callIncomingVideo => 'incoming video call';

  @override
  String get callIncomingAudio => 'incoming Sinhron call';

  @override
  String get callCalling => 'Calling…';

  @override
  String get callRinging => 'Ringing…';

  @override
  String get callOngoing => 'Call in progress';

  @override
  String get callOngoingVideo => 'Video call in progress';

  @override
  String get callJoin => 'Join';

  @override
  String get callJoinFailed => 'Couldn’t join — the call has ended.';

  @override
  String get callWaitingForPeople => 'Waiting for others to join…';

  @override
  String get callDecline => 'Decline';

  @override
  String get callAccept => 'Accept';

  @override
  String get callUnmute => 'Unmute';

  @override
  String get callFlipCamera => 'Flip';

  @override
  String get callMute => 'Mute';

  @override
  String get callSpeaker => 'Speaker';

  @override
  String get callEnd => 'End';

  @override
  String callEnded(String duration) {
    return 'Call ended · $duration';
  }

  @override
  String get callReconnecting => 'Reconnecting…';

  @override
  String get callLinkQuality => 'Connection quality';

  @override
  String get callWeakLink => 'Weak connection';

  @override
  String get callWeakLinkPeer => 'Weak connection on the other side';

  @override
  String get callAutoAudioOnly =>
      'Weak connection — camera off to keep the voice';

  @override
  String get callBarTapToReturn => 'Tap to return';

  @override
  String get contactsFavourites => 'Favourites';

  @override
  String get contactsVerified => 'Verified';

  @override
  String get contactsInvite => 'Invite friends';

  @override
  String get contactsInviteHint =>
      'Send a link — one tap adds you to their contacts';

  @override
  String get contactAdd => 'Add to contacts';

  @override
  String get contactEditName => 'Edit name';

  @override
  String get contactNameOnlyYou => 'Only you see this';

  @override
  String contactNameRestore(String name) {
    return 'Restore “$name”';
  }

  @override
  String get contactRemove => 'Remove from contacts';

  @override
  String contactRemoveConfirm(String name) {
    return 'Remove $name from contacts? The chat stays.';
  }

  @override
  String get contactFavouriteAdd => 'Add to favourites';

  @override
  String get contactFavouriteRemove => 'Remove from favourites';

  @override
  String get contactKey => 'Key';

  @override
  String get profileAboutHint =>
      'The people you chat with see it in your profile';

  @override
  String contactsAllCount(int n) {
    return 'All contacts · $n';
  }

  @override
  String get contactIdentityVerified => 'Checked by you';

  @override
  String get contactAbout => 'About';

  @override
  String get contactIdentity => 'Checking';

  @override
  String get contactMessage => 'Message';

  @override
  String get contactMediaLinksDocs => 'Media, links and docs';

  @override
  String contactGroupsInCommon(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: '$n groups in common',
      one: '1 group in common',
    );
    return '$_temp0';
  }

  @override
  String contactGroupMembers(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: '$n members',
      one: '1 member',
    );
    return '$_temp0';
  }

  @override
  String get newGroupPickOne => 'Pick at least one contact';

  @override
  String newGroupNext(int n) {
    return 'Next · $n selected';
  }

  @override
  String get newGroupAllContacts => 'All contacts';

  @override
  String get newGroupCreate => 'Create group';

  @override
  String get newGroupName => 'Group name';

  @override
  String newGroupMembersCount(int n) {
    return 'Members · $n';
  }

  @override
  String get groupInfoAdmin => 'Admin';

  @override
  String get newGroupFooter =>
      'Members get the group straight from your phone, encrypted. The server only passes it along — it can’t see who’s in it or what’s said.';

  @override
  String newGroupAddCta(int n) {
    return 'Add · $n selected';
  }

  @override
  String get newGroupNoContacts =>
      'No one to add yet. Start a personal chat with someone first — then you can put them in a group.';

  @override
  String get newGroupNoOneToAdd =>
      'Everyone you chat with is already in this group.';

  @override
  String get newGroupCreating => 'Creating the group…';

  @override
  String get groupInfoMembers => 'Members';

  @override
  String get groupInfoMediaFiles => 'Media & files';

  @override
  String get groupInfoAddMember => 'Add member';

  @override
  String groupInfoMemberYou(String name) {
    return '$name (you)';
  }

  @override
  String get blockedTitle => 'Blocked';

  @override
  String blockedCount(int n) {
    return '$n blocked';
  }

  @override
  String get blockedUnblock => 'Unblock';

  @override
  String get blockedWhatItDoes => 'What blocking does';

  @override
  String get blockedNoPresence =>
      'A blocked person never sees when you’re online.';

  @override
  String get blockedMessagesDiscarded =>
      'Their messages and reactions are dropped on this device — they aren’t told.';

  @override
  String get blockedCallsRejected =>
      'Calls in your personal chat with them are declined without ringing.';

  @override
  String get blockedNoGroups =>
      'In shared groups their messages are hidden from you; the group itself is unchanged.';

  @override
  String get blockedLocalFooter =>
      'The block list stays on this phone only. Your server never learns who you blocked.';

  @override
  String get blockedEmptyTitle => 'Nobody blocked';

  @override
  String get blockedEmptyHint =>
      'Block someone from the Info screen of a chat. Blocking works on this device only.';

  @override
  String get sharedMediaTitle => 'Shared media';

  @override
  String get sharedMediaDocuments => 'Documents';

  @override
  String get sharedMediaVoice => 'Voice';

  @override
  String get inviteLandingTitle =>
      'You’ve been invited to join a Sinhron server';

  @override
  String get inviteLandingBody =>
      'Sinhron is a private messenger that runs on a server you trust. Below is the server you’ll be joining — and who invited you.';

  @override
  String get inviteStepName => 'Pick a display name';

  @override
  String get inviteStepNameBody => 'No email, no phone, no password';

  @override
  String get inviteStepPhrase => 'Write down your 24 secret words';

  @override
  String get inviteStepPhraseBody =>
      'The only way to restore your account later';

  @override
  String get inviteStepDone => 'You’re in';

  @override
  String inviteStepDoneBody(String name) {
    return '$name will be the first contact in your list';
  }

  @override
  String get inviteAccept => 'Accept & set up';

  @override
  String get inviteHaveAccount => 'I already have an account';

  @override
  String get inviteEyebrow => 'INVITE LINK';

  @override
  String inviteReachable(int ms) {
    return 'Reachable · $ms ms';
  }

  @override
  String get inviteInvitedBy => 'Invited by';

  @override
  String inviteExpiresInHours(int n) {
    return 'Expires in ${n}h';
  }

  @override
  String get inviteNextSteps => 'NEXT STEPS';

  @override
  String get legalYourIdentity => 'Your account';

  @override
  String get safetyNumberTitle => 'Check it’s really them';

  @override
  String get serverStatus => 'Status';

  @override
  String get serverProtocol => 'Protocol';

  @override
  String get serverTrustTitle => 'TRUST';

  @override
  String get serverSees => 'What this server sees';

  @override
  String get serverCantSee => 'What it can\'t see';

  @override
  String get serverSeesTiming => 'Delivery timing';

  @override
  String get serverSeesOnline => 'When you’re online';

  @override
  String get serverSeesPush => 'Notification address';

  @override
  String get serverSeesQuota => 'How much space you use';

  @override
  String get serverHiddenContent => 'Message text';

  @override
  String get serverHiddenFiles => 'Files';

  @override
  String get serverHiddenContacts => 'Who you talk to';

  @override
  String get serverTrustFooter =>
      'That’s how the encryption itself works — the server can’t switch it off, even if it wanted to.';

  @override
  String get devicesCurrent => 'Current device';

  @override
  String get devicesOther => 'Other devices';

  @override
  String get devicesOtherFooter =>
      'Your devices share your encrypted chats. Remove one and it can no longer read anything new — from the very next message.';

  @override
  String get devicesOnlyOne =>
      'This is your only device. To use Sinhron on another one, tap “Link a new device” above.';

  @override
  String devicesRemoveAll(int n) {
    return 'Remove all other devices ($n)';
  }

  @override
  String devicesLinkedCount(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: 'devices linked',
      one: 'device linked',
    );
    return '$_temp0';
  }

  @override
  String get devicesHeroBody =>
      'Use Sinhron on all your devices at once — the chats are the same everywhere and never stored unencrypted.';

  @override
  String get devicesLinkNew => 'Link a new device';

  @override
  String devicesModelLinked(String model, String date) {
    return '$model · linked $date';
  }

  @override
  String devicesLastActive(String time) {
    return 'Last active $time';
  }

  @override
  String get devicesRevoke => 'Remove';

  @override
  String get done => 'Done';

  @override
  String get storageVideos => 'Videos';

  @override
  String get storageVoice => 'Voice messages';

  @override
  String get storageByType => 'By type';

  @override
  String get storageTopChats => 'Top chats';

  @override
  String get storageManage => 'Manage';

  @override
  String get storageMbUnit => 'MB';

  @override
  String get phraseStatusTitle => 'Secret words';

  @override
  String get phraseStatusStrength => 'Strength';

  @override
  String get phraseStatusActions => 'Actions';

  @override
  String get phraseStatusActionsFooter =>
      'The phone doesn’t keep the words once they’re saved — only what it needs to sign you in — so they can’t be shown again. Not sure you have the right words? Check them.';

  @override
  String get phraseStatusReverify => 'Check the words';

  @override
  String get phraseStatusTip =>
      'Keep the 24 words in two places — for example, in iCloud Keychain or the password manager, and on paper. They bring your whole account back — anyone who reads them can sign in as you on a new phone.';

  @override
  String get showQrTitleMy => 'My QR code';

  @override
  String get showQrTitleInvite => 'Invite to Sinhron';

  @override
  String showQrFooterMy(String username) {
    return 'Anyone who scans this QR can ask $username for a chat. It’s not a password or a secret — they can make sure it’s you later with the check number.';
  }

  @override
  String showQrFooterInvite(String server) {
    return 'Show this code to a friend, or send the link below. Anyone who scans it can request a chat with you and join $server.';
  }

  @override
  String showQrOnServer(String server) {
    return 'on $server';
  }

  @override
  String get showQrCopyLink => 'Copy link';

  @override
  String get showQrCopyKey => 'Copy address';

  @override
  String get showQrFooterReal =>
      'Anyone who scans this code can message you. It holds only your address and server — not a password, nothing secret. The other person can make sure it’s really you in the chat — “Check it’s really them”.';

  @override
  String showQrShareText(String key, String server) {
    return 'Message me on Sinhron — my address: $key\nServer: $server';
  }

  @override
  String get showQrKeyCopied => 'Address copied';

  @override
  String get scanContactNotSinhron => 'This QR code isn’t a Sinhron contact.';

  @override
  String scanContactOtherServer(String server) {
    return 'This person is on $server. Chats only work between people on the same server.';
  }

  @override
  String get scanContactSelf => 'That’s your own code.';

  @override
  String get showQrSaveImage => 'Save image';

  @override
  String get signOutTitle => 'Sign out';

  @override
  String get signOutHeading => 'Sign out from this device';

  @override
  String get signOutReminderTitle => 'Got your secret words handy?';

  @override
  String get signOutReminderBody =>
      'Without your 24 words, this device is gone for good. Your other devices keep working — but you won\'t get back on this one.';

  @override
  String get signOutWhatHappens => 'WHAT HAPPENS';

  @override
  String get signOutRowSignedOut =>
      'This device is signed out and can no longer read your chats.';

  @override
  String signOutRowOtherDevices(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: 'Your other $n devices keep working — they have their own keys.',
      one: 'Your other device keeps working — it has its own keys.',
    );
    return '$_temp0';
  }

  @override
  String get signOutRowWipe => 'Chats and keys on this device are erased.';

  @override
  String get signOutRowComeBack =>
      'To come back, sign in again with your 24 secret words.';

  @override
  String get deleteAccountTitle => 'Delete account';

  @override
  String get profileEditServerCopied => 'Server copied';

  @override
  String get profileEditKeyCopied => 'Address copied';

  @override
  String get profileEditNoPhoneNote =>
      'No phone number, no login: people reach you by your address or QR code. Only the people you chat with see your name and photo — they travel encrypted. About stays on this phone only.';

  @override
  String get profileEditIdentityFooter =>
      'Send your address or show your QR code and people can message you. With people who matter, check it’s really you two talking: Info → “Check it’s really them”.';

  @override
  String get profileEditCopyKey => 'Copy address';

  @override
  String get profileEditNotReady => 'Not ready';

  @override
  String get profileEditTapToCopy => 'Tap to copy';

  @override
  String get profileEditShowQr => 'Show my QR code';

  @override
  String get profileEditShareHandle => 'Share so people can message me';

  @override
  String get profileEditJoined => 'On Sinhron since';

  @override
  String get profileEditWhoSees => 'Who can see your profile';

  @override
  String get profileEditSignOut => 'Sign out on this device';

  @override
  String get profileEditAccountFooter =>
      'Sign out only clears this device — your other linked devices keep working. Deleting the account is immediate and can’t be undone.';

  @override
  String get profileEditTitle => 'Edit profile';

  @override
  String get profileEditChangePhoto => 'Change photo';

  @override
  String get profileEditHandle => 'Server';

  @override
  String get profileEditStrength => 'Protection';

  @override
  String get devicesHowToLink =>
      'Or, on the new device, tap “Sign in with secret words” and enter your 24 words. It joins your chats once this phone is online.';

  @override
  String get devicesUnnamed => 'Another device';

  @override
  String get devicesFirstDevice => 'first device';

  @override
  String devicesLinkedOn(String date) {
    return 'linked $date';
  }

  @override
  String get devicesRevokeTitle =>
      'Remove this device? It stops receiving your messages from the very next one.';

  @override
  String get devicesRevokeAction => 'Remove device';

  @override
  String get devicesLoadFailed =>
      'Can\'t load your devices — no connection to the server.';

  @override
  String get devicesRevokeFailed =>
      'Couldn\'t remove the device. Try again when you\'re online.';

  @override
  String get restoreTitle => 'Sign in to your account';

  @override
  String get restoreBody =>
      'Enter your 24 secret words. This phone becomes one more of your devices: your chats arrive here while your other device is online. Earlier messages stay on that device.';

  @override
  String get restoreAction => 'Continue';

  @override
  String get pairTitle => 'Link to your account';

  @override
  String get pairBody =>
      'On the device you already use, open Settings → Devices → “Link a new device” and scan this code.';

  @override
  String get pairWaiting => 'Waiting for your other device…';

  @override
  String get pairCopy => 'Copy code';

  @override
  String get pairCopied => 'Copied — paste it on your other device.';

  @override
  String get pairFailed =>
      'Couldn\'t link. Check the connection and try again.';

  @override
  String get pairUseWords => 'Enter the 24 words instead';

  @override
  String get pairCodeUsed =>
      'Another device took this code. Here is a new one — show it only to your own device.';

  @override
  String pairConfirm(String address) {
    return 'Sign in to the account with address $address? Check that your other phone shows the same address in its profile. If it doesn’t, tap Cancel.';
  }

  @override
  String get pairConfirmAction => 'Sign in';

  @override
  String get restoreUseQr => 'Your other device is nearby? Link with a QR code';

  @override
  String get addDeviceBody =>
      'On the new device choose “Link a device” — it shows a QR code. Scan it here.';

  @override
  String get addDeviceScan => 'Scan QR code';

  @override
  String get addDevicePasteHint => '…or paste the code';

  @override
  String get addDeviceAction => 'Add device';

  @override
  String get addDeviceNotACode => 'That’s not a Sinhron link code.';

  @override
  String addDeviceConfirm(String address) {
    return 'Give this device access to your account? It will receive all your new messages. The new device will ask you to check your address: $address.';
  }

  @override
  String get addDeviceConfirmAction => 'Give access';

  @override
  String get addDeviceDone =>
      'Done — the new device is signing in. It joins your chats within a minute.';

  @override
  String get addDeviceFailed =>
      'Couldn\'t send it. Check the connection and try again.';

  @override
  String get addDeviceCodeUsed =>
      'This code was already used by another device. If that wasn\'t you, don\'t confirm anything.';

  @override
  String get sealedSectionTitle => 'Anonymous messages';

  @override
  String get sealedResetAction => 'Reset access for anonymous messages';

  @override
  String get sealedResetFooter =>
      'People you chat with send you messages without the server learning who sent them. If someone you no longer talk to shouldn’t be able to, reset the access — your current chats get the new one by themselves.';

  @override
  String get sealedResetConfirm =>
      'Reset the access? Your chats get the new one by themselves; anyone else who had the old one can no longer message you anonymously.';

  @override
  String get sealedResetDone => 'Access reset';

  @override
  String get devicesNotPrimary =>
      'This device was added to your account later: adding or removing devices asks for your 24 secret words.';

  @override
  String get phrasePromptTitle => 'Enter your secret words';

  @override
  String get phrasePromptBody =>
      'This device was added to your account later. Enter your 24 secret words to go on — they’re used for this step only and aren’t stored.';

  @override
  String get phrasePromptAction => 'Confirm';

  @override
  String get proxyTitle => 'Proxy (Tor)';

  @override
  String get proxyBody =>
      'For experts: all traffic to your server goes through a proxy (SOCKS5), so the server never learns this phone’s internet address (IP) — for example Tor via Orbot at 127.0.0.1:9050. Leave empty to connect directly. Calls don’t use it.';

  @override
  String get proxySave => 'Save';

  @override
  String get proxyInvalid => 'Enter host:port, e.g. 127.0.0.1:9050.';

  @override
  String devicesSeenOn(String date) {
    return 'seen $date';
  }

  @override
  String get chatInfoTitle => 'Info';

  @override
  String get chatInfoPersonal => 'Personal chat · encrypted';

  @override
  String get chatInfoUnnamed => 'No name shared yet';

  @override
  String get chatInfoBlocked => 'Blocked';

  @override
  String get chatInfoBlock => 'Block';

  @override
  String chatInfoBlockConfirm(String name) {
    return 'Block $name? Their messages and calls won’t reach this device. They aren’t told.';
  }

  @override
  String get chatInfoMemberProfile => 'Profile';

  @override
  String get chatInfoVerify => 'Check it’s really them';

  @override
  String chatInfoMemberSafety(String name) {
    return 'Check it’s really $name';
  }

  @override
  String get incomingCalls => 'Incoming calls';

  @override
  String get incomingCallsFooter =>
      'Off: incoming calls are declined without ringing. You can still call.';

  @override
  String get blockedUnnamed => 'Someone without a name';

  @override
  String get reorderPinned => 'Reorder pinned chats';

  @override
  String get reorderPinnedTitle => 'Pinned chats';

  @override
  String get reorderHint => 'Hold a row and drag it to change the order.';

  @override
  String get chatFolders => 'Chat folders';

  @override
  String get chatFoldersHint =>
      'Folders are tabs above your chats. Hold a folder and drag it to change the order; switch it off to hide its tab.';

  @override
  String get myFolders => 'My folders';

  @override
  String get createFolder => 'Create a folder';

  @override
  String get suggestedFolders => 'Suggested';

  @override
  String get addFolder => 'Add';

  @override
  String get folderMuted => 'Muted';

  @override
  String get folderMutedHint => 'Only chats with the sound off';

  @override
  String get folderNotMuted => 'Not muted';

  @override
  String get folderNotMutedHint => 'Chats that can notify you';

  @override
  String get folderArchived => 'Archived';

  @override
  String get folderArchivedHint => 'Chats you archived';

  @override
  String folderChatCount(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: '$n chats',
      one: '1 chat',
      zero: 'No chats',
    );
    return '$_temp0';
  }

  @override
  String get folderBuiltIn => 'Standard';

  @override
  String get hideFolder => 'Hide folder';

  @override
  String showFolderTab(String name) {
    return 'Show the “$name” tab';
  }

  @override
  String get editFolders => 'Edit folders';

  @override
  String get folderChatTypes => 'Chat types';

  @override
  String get folderWhichChats => 'Which chats';

  @override
  String get onlyUnread => 'Only unread';

  @override
  String get ruleShow => 'Show';

  @override
  String get ruleHide => 'Hide';

  @override
  String get ruleOnly => 'Only these';

  @override
  String get folderRulesFooter =>
      'Muted and archived chats: keep them, leave them out, or show only them.';

  @override
  String get folderReorderHint => 'Hold a tab and drag it to move it.';

  @override
  String get verifyScan => 'Scan their code';

  @override
  String verifyScanMatch(String name) {
    return 'The codes match — $name is verified.';
  }

  @override
  String get verifyScanMismatch =>
      'The codes don\'t match. Don\'t mark this contact as verified — compare the numbers in person.';

  @override
  String get verifyScanNotCode => 'This QR isn’t a Sinhron check code.';

  @override
  String get recordVideo => 'Record video';

  @override
  String get videoFromLibrary => 'Choose from library';

  @override
  String get requestTitle => 'Message request';

  @override
  String get requestBody =>
      'Until you accept, they won\'t see that you\'ve read their messages or learn your name, and calls from this chat won\'t ring.';

  @override
  String get requestAccept => 'Accept';

  @override
  String get screenRecordingByMe => 'You are recording the screen';

  @override
  String screenRecordingByPeer(String name) {
    return '$name is recording the screen';
  }

  @override
  String get screenshotByMe => 'You took a screenshot';

  @override
  String screenshotByPeer(String name) {
    return '$name took a screenshot';
  }

  @override
  String get requestBlockFailed =>
      'Couldn\'t block — try again when you\'re connected.';

  @override
  String get errVideoTooLarge =>
      'This video is too large to send (95 MB at most), even compressed.';

  @override
  String get profileEditChoosePhoto => 'Choose photo';

  @override
  String get profileEditRemovePhoto => 'Remove photo';

  @override
  String get groupYouWereRemoved => 'You were removed from this group.';

  @override
  String groupMemberLeft(String name) {
    return '$name left the group.';
  }

  @override
  String groupYouRemoved(String names) {
    return 'You removed $names.';
  }

  @override
  String groupSomeoneAdded(String by, String names) {
    return '$by added $names.';
  }

  @override
  String groupSomeoneRemoved(String by, String names) {
    return '$by removed $names.';
  }

  @override
  String groupYouRenamed(String name) {
    return 'You renamed the group to “$name”.';
  }

  @override
  String groupSomeoneRenamed(String by, String name) {
    return '$by renamed the group to “$name”.';
  }

  @override
  String get groupLeave => 'Leave group';

  @override
  String groupLeaveConfirm(String name) {
    return 'Leave “$name”? You won’t get its messages any more, and the chat is removed from this device.';
  }

  @override
  String get groupRename => 'Rename group';

  @override
  String get groupRemoveMember => 'Remove from group';

  @override
  String groupRemoveConfirm(String name) {
    return 'Remove $name from the group? They won’t be able to read new messages.';
  }

  @override
  String get groupAdmin => 'admin';

  @override
  String get groupNotMember => 'You’re no longer a member of this group.';

  @override
  String get groupActionFailed =>
      'Couldn’t do that — check your connection and try again.';

  @override
  String get chatMissedCall => 'Missed call';

  @override
  String get chatMissedVideoCall => 'Missed video call';

  @override
  String get callNoAnswer => 'No answer';

  @override
  String get callCouldntConnect => 'Couldn’t connect the call';

  @override
  String get callNotEncrypted =>
      'Call ended: the server tried to turn off encryption';

  @override
  String get callBusy => 'Busy';

  @override
  String get callDeclinedByPeer => 'Declined';

  @override
  String get callMissedShort => 'Missed call';

  @override
  String get callsBusy => 'Busy';

  @override
  String get callsCancelled => 'Cancelled';

  @override
  String get callsMissedOne => 'Missed';

  @override
  String get callsCallBack => 'Call back';

  @override
  String get callsOpenChat => 'Open chat';

  @override
  String get storageOther => 'Other';

  @override
  String get storageDatabase => 'Messages';

  @override
  String get storageUsedHere => 'used by Sinhron on this phone';

  @override
  String get storageTopChatsRealFooter =>
      'Copies of photos, videos, voice messages and files kept on this phone, by chat.';

  @override
  String get storageClearCopies => 'Delete media copies';

  @override
  String get storageClearCopiesConfirm =>
      'Delete the copies of photos, videos and files kept on this phone? Messages stay. A file loads from the server again when you open it — but one the server has already deleted (90 days after anyone last opened it) won’t come back.';

  @override
  String storageCopiesCleared(String size) {
    return 'Freed $size';
  }

  @override
  String get storageClearCopiesFooter =>
      'Media copies let files open without the internet and keep them after the server deletes old files. Messages and their text are never deleted here.';

  @override
  String get deleteAccountWord => 'DELETE';

  @override
  String get deleteAccountCannotUndo => 'This can’t be undone';

  @override
  String deleteAccountServer(String server) {
    return 'Your account is removed from $server right away: your address, devices and messages waiting for you.';
  }

  @override
  String get deleteAccountGroups =>
      'Your groups are told you left; people can no longer write to you.';

  @override
  String get deleteAccountThisPhone =>
      'Chats, media and keys are erased from this phone.';

  @override
  String deleteAccountOtherDevices(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: 'Your $n other devices stop working.',
      one: 'Your other device stops working.',
    );
    return '$_temp0';
  }

  @override
  String get deleteAccountSentStays =>
      'Messages and files you already sent stay with the people who received them.';

  @override
  String get deleteAccountPhrase =>
      'Your 24 words can register again, but these chats and groups won’t come back. The chat backup is deleted from iCloud / Google Drive too, if this phone can reach it.';

  @override
  String deleteAccountTypeWord(String word) {
    return 'Type $word to confirm';
  }

  @override
  String get deleteAccountFailed =>
      'Couldn’t delete the account — check your connection and try again. Nothing was erased.';

  @override
  String get reportAction => 'Report';

  @override
  String reportTitle(String name) {
    return 'Report $name?';
  }

  @override
  String reportBody(String server) {
    return 'The report goes to the operator of $server. They can’t read your chats — only what you choose to send.';
  }

  @override
  String get reportWithMessage => 'Report and send this message';

  @override
  String get reportWithoutMessage => 'Report without the message';

  @override
  String get reportAndBlock => 'Report and block';

  @override
  String get reportReasonTitle => 'What’s wrong?';

  @override
  String get reportReasonSpam => 'Spam';

  @override
  String get reportReasonAbuse => 'Harassment or threats';

  @override
  String get reportReasonIllegal => 'Illegal content';

  @override
  String get reportReasonOther => 'Something else';

  @override
  String get reportSent => 'Report sent. Thank you.';

  @override
  String get reportFailed =>
      'Couldn’t send the report — check your connection and try again.';

  @override
  String get legalSection => 'Help & rules';

  @override
  String get legalTermsRow => 'Terms of use';

  @override
  String get legalPrivacyRow => 'Privacy policy';

  @override
  String get reportProblemTitle => 'Report a problem';

  @override
  String get reportProblemHint => 'Send the app’s log to whoever helps you';

  @override
  String get reportProblemNoteHint =>
      'What happened? E.g. “the call connected but there was no sound”';

  @override
  String get reportProblemWhat =>
      'The report holds the app’s log for the last hour — connection, notifications, calls — the app version and phone model. No message text, names or keys.';

  @override
  String get reportProblemPreview => 'View the report';

  @override
  String get reportProblemHidePreview => 'Hide the report';

  @override
  String get reportProblemSend => 'Send';

  @override
  String get reportProblemCopy => 'Copy';

  @override
  String get reportProblemCopied => 'Report copied';

  @override
  String get pasteMarkdownDone => 'Markdown turned into formatting';

  @override
  String get pasteMarkdownRevert => 'Undo';

  @override
  String get reportProblemFailed =>
      'Couldn’t put the report together. Try again.';

  @override
  String get reportProblemSendHint =>
      'Send opens the share menu: pick Sinhron and the chat with the person who helps you — or Telegram or mail if Sinhron can’t connect.';

  @override
  String get backupTitle => 'Chat backup';

  @override
  String get backupHint => 'Your chats and media, in your own cloud';

  @override
  String get backupWhere => 'Kept in';

  @override
  String get backupWhereDrive => 'Google Drive';

  @override
  String get backupNotConnected => 'Not connected';

  @override
  String get backupSignInGoogle => 'Sign in with Google';

  @override
  String get backupSignOutGoogle => 'Sign out of Google';

  @override
  String get backupIcloudOff =>
      'Turn on iCloud Drive in the iPhone’s settings (your name → iCloud → iCloud Drive)';

  @override
  String get backupDaily => 'Back up every day';

  @override
  String get backupLast => 'Last backup';

  @override
  String get backupNever => 'Not yet';

  @override
  String get backupNow => 'Back up now';

  @override
  String get backupRunning => 'Backing up…';

  @override
  String backupRunningMedia(int done, int total) {
    return 'Media $done of $total';
  }

  @override
  String get backupFailed => 'Didn’t finish. Check the internet and try again.';

  @override
  String get backupDone => 'Backup saved';

  @override
  String get backupRestoreSection => 'Restore';

  @override
  String get backupRestore => 'Restore from backup';

  @override
  String backupRestoreNone(String where) {
    return 'No backup found in $where';
  }

  @override
  String get backupRestoreAskTitle => 'Restore your chats?';

  @override
  String backupRestoreAskBody(String date, int messages, int chats, int media) {
    return 'Backup of $date: $messages messages in $chats chats, $media media files.';
  }

  @override
  String backupRestoreOlder(String newer) {
    return 'A newer backup ($newer) is not in the cloud any more — this one is older. Messages after it will be missing.';
  }

  @override
  String get backupRestoreGo => 'Restore';

  @override
  String backupRestoring(int done, int total) {
    return 'Restoring… $done of $total';
  }

  @override
  String get backupRestored => 'Chats restored';

  @override
  String backupRestoredAdded(int n) {
    return 'Chats restored: $n messages added';
  }

  @override
  String get backupRestoredNothingNew =>
      'Nothing new in the backup — it’s all here already';

  @override
  String get backupUploadPending =>
      'Still uploading to iCloud — your other devices see it once this iPhone sends it (usually on Wi‑Fi)';

  @override
  String get backupFooter =>
      'The backup is encrypted with your 24 secret words: neither Apple nor Google can read it, and without the words it can’t be restored.';

  @override
  String get backupUnlockRow => 'Turn on backup on this device';

  @override
  String get backupUnlockRowHint => 'Needs your 24 words — once';

  @override
  String get backupUnlockTitle => 'Turn on backup here';

  @override
  String get backupUnlockBody =>
      'This device was linked before backups existed. Type your 24 words once — the words themselves aren’t kept.';

  @override
  String get backupUnlockGo => 'Turn on';

  @override
  String get backupUnlockOtherWords => 'These are another account’s words';

  @override
  String get backupOfferDriveTitle => 'Look for a chat backup in Google Drive?';

  @override
  String get backupOfferDriveBody =>
      'If your old phone made a backup, your chats come back. Sign in to the same Google account.';

  @override
  String get backupOfferDriveGo => 'Sign in with Google';

  @override
  String get backupRestoreStarted =>
      'Restoring your chats — you can use the app meanwhile';

  @override
  String get oldDevicesTitle => 'Your other devices';

  @override
  String get oldDevicesBody =>
      'If your old phone is lost, sold or broken, disconnect it: it gets no more messages or calls and leaves your chats. Only now, while your 24 words are in.';

  @override
  String get oldDevicesDisconnect => 'Disconnect';

  @override
  String get oldDevicesDisconnected => 'Disconnected';

  @override
  String get legalSupportRow => 'Help & support';

  @override
  String get legalTermsIntro =>
      'By using Sinhron you agree to these rules. They apply to everyone on this server.';

  @override
  String get legalTermsBody =>
      'No tolerance for objectionable content or abusive people. Don’t send spam, threats, harassment, hate, sexual content involving minors, or anything illegal where you or the recipient live.\n\nReport and block. In any chat you can report a person or a message. The report goes to the operator of your server, who reviews it and may remove the account — usually within 24 hours. Blocking hides a person from you at once.\n\nYour messages are end-to-end encrypted: the operator can’t read them. A report contains only what you choose to send.\n\nThe operator may remove accounts that break these rules. You can delete your account at any time in Profile → Delete account.';

  @override
  String get legalPrivacyBody =>
      'Messages, calls, photos and files are encrypted on your devices; the server only passes them along encrypted and can’t read them.\n\nThe server knows: your Sinhron address, your devices, which groups you are in, and when messages are sent — that is what it needs to deliver them. It doesn’t know your name, photo, contacts or message content.\n\nNothing is sold or shared with advertisers. No ads, no analytics.\n\nDelete your account at any time (Profile → Delete account): the server removes your address, devices and messages waiting for you.';

  @override
  String get legalSupportBody =>
      'Questions, problems, a report about someone: write to the operator of your server.';

  @override
  String legalSupportOperator(String server) {
    return 'Server: $server';
  }

  @override
  String get legalSupportReportHint =>
      'To report a person or a message, long-press the message or open the chat’s info and choose Report.';

  @override
  String get welcomeAgreeTerms => 'By continuing you accept the Terms of use';

  @override
  String get pushToggle => 'Message notifications';

  @override
  String get pushFooterOn =>
      'When Sinhron is closed, your phone shows “New message” — no text and no name: your server can’t read messages. Previews come with a future version.';

  @override
  String get pushDenied =>
      'Notifications are off in iOS Settings → Sinhron → Notifications.';

  @override
  String get pushNoDistributor =>
      'There’s no notification app on this phone. Install ntfy (Google Play or F-Droid) — Sinhron wakes the phone through it. Which server to set in ntfy shows here once Sinhron is online.';

  @override
  String get keepConnected => 'Always connected';

  @override
  String get keepConnectedFooter =>
      'Only needed if calls and messages don’t arrive while Sinhron is closed. It usually turns on and off by itself: when it isn’t needed it only drains the battery.';

  @override
  String get callsReachYes => 'Calls will reach you: yes';

  @override
  String get callsReachNo => 'Calls will reach you: not yet — what to do';

  @override
  String get callsReachViaGoogle =>
      'Even when Sinhron is closed or swiped away. Google only sees that something came for Sinhron, not what or from whom.';

  @override
  String get callsReachViaNtfy => 'Even when Sinhron is closed.';

  @override
  String get callsReachViaAlways =>
      'Through “Always connected”: Sinhron stays online in the background.';

  @override
  String get callsReachNone =>
      'Nothing wakes this phone while Sinhron is closed.';

  @override
  String get reachFixNotifications => 'Allow notifications';

  @override
  String get reachFixCalls => 'Turn on incoming calls';

  @override
  String get reachFixAlways => 'Turn on “Always connected”';

  @override
  String get reachFixBackground => 'Let Sinhron run in the background';

  @override
  String get reachSamsung => 'Samsung: “Never sleeping apps”';

  @override
  String get reachSamsungSub =>
      'Add Sinhron there so the phone never puts it to sleep';

  @override
  String get ntfyTitle => 'Notifications through ntfy';

  @override
  String ntfyInstallSteps(String url) {
    return 'To wake this phone, Sinhron needs the free ntfy app.\n1. Install ntfy from Google Play or F-Droid.\n2. In ntfy open the ⋮ menu → Settings → Default server and enter $url\n3. Come back here and tap “Connect ntfy”.';
  }

  @override
  String ntfySetServerSteps(String url) {
    return 'ntfy is installed but not connected yet.\n1. In ntfy open the ⋮ menu → Settings → Default server and enter $url\n2. Come back here and tap “Connect ntfy”.';
  }

  @override
  String ntfyOtherServerSteps(String other, String url) {
    return 'ntfy uses another server ($other) — Sinhron notifications don’t come through it.\n1. In ntfy open the ⋮ menu → Settings → Default server and enter $url\n2. Come back here and tap “Connect ntfy”.';
  }

  @override
  String get ntfyServerHasNone =>
      'Your Sinhron server doesn’t send notifications to Android phones. Turn on “Always connected” below — then Sinhron stays online by itself.';

  @override
  String get ntfyCopyAddress => 'Copy the server address';

  @override
  String get ntfyAddressCopied => 'Address copied';

  @override
  String get ntfyInstall => 'Install ntfy';

  @override
  String get ntfyOpen => 'Open ntfy';

  @override
  String get ntfyConnect => 'Connect ntfy';

  @override
  String get ntfyConnecting => 'Connecting ntfy…';

  @override
  String get asInSystem => 'As in system settings';

  @override
  String get setPasscodeFirstAndroid =>
      'Set a screen lock on this phone first — App Lock uses it.';

  @override
  String get appLockFooterAndroid =>
      'When on, Sinhron asks for your fingerprint, face or screen lock when it opens. Your chats stay encrypted either way.';

  @override
  String get unlockPhraseNoteAndroid =>
      'The words never leave the phone and aren’t stored — the phone keeps only a key made from them, in Android’s protected storage.';

  @override
  String get navErrNotConnected =>
      'No connection to the server — reconnecting. Try again in a few seconds.';

  @override
  String get callSwitchingPath =>
      'The call keeps dropping — switching to the backup route…';

  @override
  String get callsReserveSection => 'Calls';

  @override
  String get callsReserve => 'Calls over the backup route';

  @override
  String get callsReserveFooter =>
      'Sound and video go through your server the same way a normal website loads — for networks where calls connect and then drop. Still encrypted. Sinhron also switches by itself when a call keeps dropping.';

  @override
  String inviteShareText(String link) {
    return 'Join me on Sinhron — an encrypted messenger. Install the app and tap the link, I\'ll be in your contacts right away: $link';
  }

  @override
  String get inviteForged =>
      'This invite link was changed or forged — not opening it. Ask the person to send it again.';

  @override
  String get inviteDamaged =>
      'This invite link is damaged. Ask the person to send it again.';

  @override
  String get inviteExpired => 'This link has expired — ask for a new one';

  @override
  String get inviteOffline =>
      'Couldn\'t open the invite — no connection to its server. Tap the link again a bit later.';

  @override
  String inviteKeyRow(String fingerprint) {
    return 'Address $fingerprint';
  }

  @override
  String get inviteYourServer => 'Your server';

  @override
  String inviteAddContact(String name) {
    return 'Add $name to contacts';
  }

  @override
  String get inviteServerChecking => 'Checking the server…';

  @override
  String get inviteServerOk => 'Server is reachable';

  @override
  String get inviteServerUnreachable =>
      'Server doesn\'t answer right now — you can still go on';

  @override
  String get inviteNotSinhron => 'This address isn\'t a Sinhron server';

  @override
  String get inviteNotSaved =>
      'Couldn\'t save the server on this phone — try again';

  @override
  String get notificationPreviewTitle => 'Notifications show';

  @override
  String get notificationPreviewNameAndText => 'Name and message';

  @override
  String get notificationPreviewNameOnly => 'Name only';

  @override
  String get notificationPreviewNothing => 'Nothing — just \"New message\"';

  @override
  String get notificationPreviewFooter =>
      'For banners in the app, Android notifications and the name in the iPhone\'s call history. On an iPhone with Sinhron closed a notification always says just \"New message\": your server can\'t read who wrote or what.';

  @override
  String get callDiagnostics => 'Call diagnostics';

  @override
  String get callShareScreen => 'Share screen';

  @override
  String get callSharingScreen => 'You\'re sharing your screen';

  @override
  String get callStopSharing => 'Stop';

  @override
  String callScreenOf(String name) {
    return '$name is sharing the screen';
  }

  @override
  String get callScreenBackToCall => 'Back to call';

  @override
  String callScreenWatch(String name) {
    return 'Watch screen: $name';
  }

  @override
  String get callScreenRotate => 'Rotate';

  @override
  String get callScreenShareFailed => 'Couldn\'t share the screen';

  @override
  String get callAudioOutput => 'Audio output';

  @override
  String get callAudioPhone => 'Phone';

  @override
  String get callAudioHeadphones => 'Headphones';

  @override
  String get callAudioCar => 'Car';

  @override
  String get callAudioOther => 'Other device';

  @override
  String get callKeepsDropping =>
      'The call keeps dropping. If a VPN is on, try turning it off';

  @override
  String get searchCalls => 'Search calls';

  @override
  String get callsNewCallTitle => 'Call whom?';

  @override
  String get storageKeepCopies => 'Keep media copies';

  @override
  String get storageKeepForever => 'Forever';

  @override
  String get storageKeepMonth => 'A month';

  @override
  String get storageKeepWeek => 'A week';

  @override
  String get storageKeepFooter =>
      'A copy nobody opened for that long is deleted from this phone; the message stays and the file loads from the server again while the server has it (90 days after anyone last loaded it).';

  @override
  String get emojiRecent => 'Recent';

  @override
  String get emojiSmileys => 'Smileys & Emotion';

  @override
  String get emojiPeople => 'People & Body';

  @override
  String get emojiAnimals => 'Animals & Nature';

  @override
  String get emojiFood => 'Food & Drink';

  @override
  String get emojiActivities => 'Activity';

  @override
  String get emojiTravel => 'Travel & Places';

  @override
  String get emojiObjects => 'Objects';

  @override
  String get emojiSymbols => 'Symbols';

  @override
  String get emojiFlags => 'Flags';

  @override
  String get emojiDelete => 'Delete';

  @override
  String get emojiKeyboard => 'Keyboard';

  @override
  String get emojiTab => 'Emoji';

  @override
  String get stickersTab => 'Stickers';

  @override
  String get emojiSearch => 'Search emoji';

  @override
  String get emojiNothingFound => 'Nothing found';

  @override
  String get emojiSkinTone => 'Skin tone';

  @override
  String get stickersAdd => 'Add stickers';

  @override
  String get stickersFromFiles => 'From files — .tgs, .webp, .webm, .zip';

  @override
  String get stickersFromCode => 'Paste a link or pack code';

  @override
  String get stickersNoCode =>
      'Copy a t.me/addstickers/… link or a pack code, then tap again';

  @override
  String get stickersImporting => 'Adding stickers…';

  @override
  String get stickersImportFailed => 'Couldn\'t add stickers: no usable files';

  @override
  String stickersImported(String title) {
    return 'Pack “$title” added';
  }

  @override
  String get myStickersTitle => 'My stickers';

  @override
  String get stickersAll => 'All';

  @override
  String get stickersFound => 'Found';

  @override
  String stickersNone(String emoji) {
    return 'No stickers with $emoji';
  }

  @override
  String stickerPackAdd(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count stickers',
      one: '$count sticker',
    );
    return 'Add $_temp0';
  }

  @override
  String get stickerPackAdded => 'Pack added';

  @override
  String get stickerPackAlready => 'You already have this pack';

  @override
  String get stickerPackShare => 'Share pack';

  @override
  String get stickerPackCopyCode => 'Copy pack code';

  @override
  String get stickerPackCodeCopied => 'Pack code copied';

  @override
  String stickerPackShareText(String code) {
    return 'My stickers for Sinhron — in the sticker panel tap + and paste this code: $code';
  }

  @override
  String get stickerPackDelete => 'Remove pack';

  @override
  String get stickerPackBuiltin => 'Built-in pack';

  @override
  String stickerPackCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count stickers',
      one: '$count sticker',
    );
    return '$_temp0';
  }

  @override
  String get stickerPackUnavailable =>
      'Couldn\'t open the pack — check the connection';

  @override
  String get stickerPackNotShared => 'This sticker came without its pack';

  @override
  String get stickerPackOptions => 'Pack options';

  @override
  String get tgPackFrom => 'From Telegram';

  @override
  String get tgPackLoading => 'Opening the Telegram pack…';

  @override
  String tgPackDownloading(int done, int total) {
    return 'Downloading stickers: $done of $total';
  }

  @override
  String get tgPackNotFound => 'Pack not found — check the link';

  @override
  String get tgPackNotConfigured =>
      'The server isn\'t set up for Telegram packs yet — ask whoever runs it';

  @override
  String get tgPackServerOld =>
      'The server can\'t fetch Telegram packs yet — it needs an update';

  @override
  String get tgPackUnreachable =>
      'The server can\'t reach Telegram right now — try later';

  @override
  String get tgPackRateLimited =>
      'Too many packs in a row — try again in a few minutes';

  @override
  String get tgPackFailed => 'Couldn\'t load the pack — check the connection';

  @override
  String get tgPackAddToSinhron => 'Add the stickers to Sinhron';

  @override
  String tgPackAddedPartly(String title, int count) {
    return 'Pack “$title” added; $count didn\'t load';
  }

  @override
  String get kindSticker => 'Sticker';

  @override
  String get whatSticker => 'sticker';

  @override
  String a11ySticker(String emoji) {
    return 'Sticker $emoji';
  }

  @override
  String get accentBlue => 'Blue';

  @override
  String get accentViolet => 'Violet';

  @override
  String get accentGreen => 'Green';

  @override
  String get accentOrange => 'Orange';

  @override
  String get accentPink => 'Pink';

  @override
  String get accentGraphite => 'Graphite';

  @override
  String get tapToReveal => 'Tap to reveal';

  @override
  String get textSelectAll => 'Select All';

  @override
  String get textPaste => 'Paste';

  @override
  String get textCut => 'Cut';

  @override
  String get formatMenu => 'Format';

  @override
  String get formatBold => 'Bold';

  @override
  String get formatItalic => 'Italic';

  @override
  String get formatUnderline => 'Underline';

  @override
  String get formatStrike => 'Strikethrough';

  @override
  String get formatMono => 'Monospace';

  @override
  String get formatSpoiler => 'Spoiler';

  @override
  String get formatLink => 'Link';

  @override
  String get formatQuote => 'Quote';

  @override
  String get formatClear => 'Clear formatting';

  @override
  String get linkSheetTitle => 'Link';

  @override
  String get linkSheetHint => 'Address, e.g. https://…';

  @override
  String get linkSheetBad => 'That doesn\'t look like an address';

  @override
  String get linkSheetDone => 'Done';

  @override
  String get linkSheetRemove => 'Remove link';

  @override
  String get linkHiddenWarning =>
      'The link text and its address differ — check where it leads';

  @override
  String get codeCopy => 'Copy';

  @override
  String get codeCopied => 'Code copied';

  @override
  String get a11ySpoiler => 'Hidden text, double-tap to show';

  @override
  String get a11yQuote => 'Quote';

  @override
  String get a11yCodeBlock => 'Code';

  @override
  String get callBarIncoming => 'Incoming call';

  @override
  String get callBarEnded => 'Call ended';

  @override
  String get profileSaveFailed => 'Couldn\'t save the profile — try again';

  @override
  String get signOutFailed => 'Couldn\'t sign out — try again';

  @override
  String get startingChat => 'Starting an encrypted chat…';

  @override
  String get restoreFailed =>
      'Couldn\'t sign in — check the connection and try again. The words are still here.';

  @override
  String get requestAcceptFailed =>
      'Couldn\'t accept the request — check the connection and try again';

  @override
  String get sendQueuedOffline =>
      'No connection — the message will go out by itself when it\'s back';

  @override
  String safetyNumberA11y(String groups) {
    return 'Check number: $groups';
  }

  @override
  String callMicMode(String mode) {
    return 'Mic: $mode';
  }

  @override
  String get callMicStandard => 'Standard';

  @override
  String get callMicVoiceIsolation => 'Voice Isolation';

  @override
  String get callMicWideSpectrum => 'Wide Spectrum';

  @override
  String get callMinimize => 'Minimise — the call goes on';

  @override
  String get callPeerMicOff => 'Mic off';

  @override
  String get callConnecting => 'Connecting…';

  @override
  String get callBarReturn => 'tap to return';

  @override
  String get callBarAnswer => 'tap to answer';

  @override
  String get myProfileTitle => 'My profile';

  @override
  String get myProfileShare => 'Share so people can message me';

  @override
  String get myProfileQrHint =>
      'Show this code — scanning it lets people message you. It isn’t a password: there’s nothing secret in it.';

  @override
  String get myProfileAddress => 'Your Sinhron address';

  @override
  String get myProfileNotReady =>
      'Your address appears once the phone connects to the server.';

  @override
  String get myProfileNoBio => 'A few words about you — tap Edit';

  @override
  String get settingsProfileHint =>
      'Profile and QR code so people can message you';

  @override
  String get settingsNotificationsHint =>
      'Sound, vibration and what a notification shows';

  @override
  String get settingsPrivacyHint => 'Who sees you online and your read ticks';

  @override
  String get settingsAppLockHint => 'Ask for Face ID or a passcode on opening';

  @override
  String get settingsAppLockHintAndroid =>
      'Ask for a fingerprint or screen lock on opening';

  @override
  String get settingsAppearanceHint => 'Theme, colour and wallpaper';

  @override
  String get settingsChatsSection => 'Chats & folders';

  @override
  String get settingsNewFolderHint => 'For example Work or Family';

  @override
  String get settingsArchiveHint => 'Chats you moved out of the list';

  @override
  String get settingsStorageHint => 'How much space photos and videos take';

  @override
  String get settingsAccountSection => 'Account & devices';

  @override
  String get settingsDevicesHint => 'Phones and computers with your account';

  @override
  String get settingsWordsHint => 'Bring your account back on a new phone';

  @override
  String get settingsAdvanced => 'Advanced';

  @override
  String get settingsProxyHint =>
      'Hide your phone’s IP from the server; backup route for calls';

  @override
  String get settingsHelpHint => 'Questions, problems, reports';

  @override
  String get transferOutTitle => 'Moving everything to your new device';

  @override
  String get transferInTitle =>
      'Bringing everything over from your other device';

  @override
  String get transferStageBuild => 'Packing chats, contacts and settings…';

  @override
  String transferStageUpload(int done, int total) {
    return 'Sending: $done of $total';
  }

  @override
  String get transferStageOffer => 'Telling your new device…';

  @override
  String transferStageMedia(int done, int total) {
    return 'Photos and files: $done of $total';
  }

  @override
  String get transferStageManifest => 'Getting ready…';

  @override
  String transferStageParts(int done, int total) {
    return 'Receiving chats: $done of $total';
  }

  @override
  String get transferStagePacks => 'Loading sticker packs…';

  @override
  String transferDone(int messages) {
    return 'Done — $messages messages moved';
  }

  @override
  String transferDoneMediaLater(int messages) {
    return '$messages messages are here. Photos and files open as your other device puts them up';
  }

  @override
  String transferDoneMissing(int messages, int missing) {
    return 'Done — $messages messages. $missing photos and files were no longer anywhere';
  }

  @override
  String get transferFailed =>
      'The transfer didn\'t finish. On your other device: Devices → this device → Send everything';

  @override
  String get transferWaiting =>
      'No connection — it carries on when you\'re back online';

  @override
  String get transferHide => 'Hide';

  @override
  String get transferStop => 'Stop';

  @override
  String transferStrip(int percent) {
    return 'Bringing your chats over… $percent%';
  }

  @override
  String get devicesSendAll => 'Send everything to this device';

  @override
  String get devicesSendAllFailed =>
      'Couldn\'t start the transfer. Check the connection and try again.';

  @override
  String get devicesSyncNote =>
      'Your devices stay in step: chats with their whole history, contacts, blocked people, sticker packs, folders and privacy settings. Look, sounds and connection settings stay per device.';

  @override
  String get serverChatTitle => 'Server';

  @override
  String get serverChatSubtitle => 'Service notices · for the administrator';

  @override
  String get serverChatEmpty => 'All quiet — no notices yet.';

  @override
  String get serverChatFooter =>
      'Your server writes here because you are its administrator. You can\'t reply. Notices are kept on the server for 30 days. Long press — copy.';

  @override
  String get previewReply => 'So jealous! Take me with you next time? 😍';

  @override
  String get previewSure => 'Of course! 🙌';

  @override
  String get wallSameAsAll => 'Same as all chats';

  @override
  String get shareContact => 'Share contact';

  @override
  String get shareContactTo => 'Send contact to…';

  @override
  String get contactSent => 'Contact sent';

  @override
  String get contactCardNoName => 'Contact';

  @override
  String get contactCardNameUnverified => 'Name from the card, not checked';

  @override
  String contactCardPreview(String name) {
    return 'Contact: $name';
  }
}
