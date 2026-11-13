// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_l10n.dart';

// ignore_for_file: type=lint

/// The translations for Russian (`ru`).
class AppL10nRu extends AppL10n {
  AppL10nRu([String locale = 'ru']) : super(locale);

  @override
  String get chatsTitle => 'Чаты';

  @override
  String get tabChats => 'Чаты';

  @override
  String get tabCalls => 'Звонки';

  @override
  String get tabContacts => 'Контакты';

  @override
  String get tabSettings => 'Настройки';

  @override
  String get folderAll => 'Все';

  @override
  String get folderPersonal => 'Личные';

  @override
  String get folderGroups => 'Группы';

  @override
  String get folderUnread => 'Непрочитанные';

  @override
  String get cancel => 'Отмена';

  @override
  String get mute => 'Без звука';

  @override
  String get archive => 'В архив';

  @override
  String get pin => 'Закрепить';

  @override
  String get markUnread => 'Не прочитано';

  @override
  String get editFolder => 'Изменить папку';

  @override
  String get moveLeft => 'Сдвинуть влево';

  @override
  String get moveRight => 'Сдвинуть вправо';

  @override
  String get markAllRead => 'Прочитать все';

  @override
  String get deleteFolder => 'Удалить папку';

  @override
  String get chatsLoadError => 'Не удалось загрузить чаты';

  @override
  String get pullToRetry => 'Потяните вниз, чтобы повторить.';

  @override
  String get noChatsYet => 'Чатов пока нет';

  @override
  String get noChatsHint =>
      'Нажмите на карандаш вверху, чтобы написать кому-нибудь.';

  @override
  String get noChatsHere => 'Здесь пока пусто';

  @override
  String folderEmptyHint(String name) {
    return 'Здесь появятся чаты папки «$name».';
  }

  @override
  String get archivedChats => 'Архив';

  @override
  String get unmute => 'Включить звук';

  @override
  String get unarchive => 'Вернуть из архива';

  @override
  String get delete => 'Удалить';

  @override
  String get open => 'Открыть';

  @override
  String get unpin => 'Открепить';

  @override
  String get moveUp => 'Выше';

  @override
  String get moveDown => 'Ниже';

  @override
  String get markRead => 'Прочитано';

  @override
  String get deleteChat => 'Удалить чат';

  @override
  String deleteChatConfirm(String name) {
    return 'Удалить чат с $name? Сообщения на этом устройстве удалятся навсегда.';
  }

  @override
  String get noMessagesYet => 'Сообщений пока нет';

  @override
  String deleteFolderConfirm(String name) {
    return 'Удалить папку «$name»? Чаты останутся на месте.';
  }

  @override
  String get newFolder => 'Новая папка';

  @override
  String get save => 'Готово';

  @override
  String get folderName => 'Название папки';

  @override
  String get include => 'Включить';

  @override
  String get allPersonal => 'Все личные чаты';

  @override
  String get allGroups => 'Все группы';

  @override
  String get hide => 'Скрыть';

  @override
  String get archivedNotInFolders => 'Чаты из архива в папках не показываются.';

  @override
  String get mutedChats => 'Чаты без звука';

  @override
  String get readChats => 'Прочитанные чаты';

  @override
  String chatsInFolderCount(int n) {
    return 'Чаты · в папке: $n';
  }

  @override
  String get folderChatHint =>
      'Нажмите на чат, чтобы всегда включать его, ещё раз — чтобы всегда скрывать.';

  @override
  String get included => 'Включён';

  @override
  String get hidden => 'Скрыт';

  @override
  String get byRule => 'По правилу';

  @override
  String get noArchivedChats => 'В архиве пусто';

  @override
  String get archiveHint =>
      'Смахните чат влево и нажмите «В архив», чтобы убрать его сюда.';

  @override
  String get searchHint => 'Поиск по сообщениям и чатам';

  @override
  String get searchRecent => 'Недавние';

  @override
  String get searchRecentClear => 'Очистить';

  @override
  String searchRecentRemove(String name) {
    return 'Убрать $name из недавних';
  }

  @override
  String get searchEmptyTitle => 'Поиск по чатам и сообщениям';

  @override
  String get searchPrivacy =>
      'Поиск идёт только на этом телефоне — сервер не знает, что вы ищете.';

  @override
  String get messagesSection => 'Сообщения';

  @override
  String groupWithTime(String time) {
    return 'Группа · $time';
  }

  @override
  String noResults(String query) {
    return 'Ничего не нашлось по «$query»';
  }

  @override
  String get noResultsHint =>
      'Попробуйте слово короче или другое написание. Поиск смотрит только сообщения на этом телефоне.';

  @override
  String get openLink => 'Открыть ссылку';

  @override
  String get errLibrary => 'Галерея недоступна';

  @override
  String get messageDeleted => 'Сообщение удалено';

  @override
  String get replyToYourself => 'Ответ себе';

  @override
  String replyTo(String name) {
    return 'Ответ $name';
  }

  @override
  String get statusFailed => 'Не отправлено';

  @override
  String get messageNotSent => 'Не отправлено · Нажмите, чтобы повторить';

  @override
  String get retrySend => 'Повторить';

  @override
  String get msgInfo => 'Инфо';

  @override
  String get msgInfoSent => 'Отправлено';

  @override
  String get msgInfoDelivered => 'Доставлено';

  @override
  String get msgInfoRead => 'Прочитано';

  @override
  String get msgInfoNotYet => 'Ещё не доставлено';

  @override
  String get statusSending => 'Отправляется';

  @override
  String get statusSent => 'Отправлено';

  @override
  String get statusDelivered => 'Доставлено';

  @override
  String get kindVoice => 'Голосовое сообщение';

  @override
  String timerMinutes(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: '$n минуты',
      many: '$n минут',
      few: '$n минуты',
      one: '$n минута',
    );
    return '$_temp0';
  }

  @override
  String timerHours(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: '$n часа',
      many: '$n часов',
      few: '$n часа',
      one: '$n час',
    );
    return '$_temp0';
  }

  @override
  String timerDays(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: '$n дня',
      many: '$n дней',
      few: '$n дня',
      one: '$n день',
    );
    return '$_temp0';
  }

  @override
  String timerWeeks(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: '$n недели',
      many: '$n недель',
      few: '$n недели',
      one: '$n неделя',
    );
    return '$_temp0';
  }

  @override
  String get couldNotEdit => 'Не удалось изменить сообщение';

  @override
  String get reply => 'Ответить';

  @override
  String get copy => 'Копировать';

  @override
  String get forward => 'Переслать';

  @override
  String get savedMessages => 'Избранное';

  @override
  String get savedMessagesHint => 'Заметки и файлы — на всех устройствах';

  @override
  String get saveToSaved => 'В избранное';

  @override
  String get savedToSaved => 'Сохранено в «Избранное»';

  @override
  String get savedMessagesFailed =>
      'Не удалось открыть «Избранное» — проверьте связь и попробуйте ещё раз';

  @override
  String get edit => 'Изменить';

  @override
  String get select => 'Выбрать';

  @override
  String get selectText => 'Выделить текст';

  @override
  String get copyAll => 'Копировать всё';

  @override
  String get selectTextClose => 'Закрыть';

  @override
  String deleteMessagesConfirm(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: 'Удалить $n сообщений?',
      few: 'Удалить $n сообщения?',
      one: 'Удалить $n сообщение?',
    );
    return '$_temp0';
  }

  @override
  String get deleteForEveryone => 'Удалить у всех';

  @override
  String get deleteForMe => 'Удалить у меня';

  @override
  String get call => 'Позвонить';

  @override
  String get timerSheetTitle =>
      'Исчезающие сообщения — новые сообщения в этом чате удалятся на обоих телефонах через:';

  @override
  String get timerOff => 'Выключено';

  @override
  String get errNotEncrypted =>
      'Этот чат не зашифрован — из него ничего нельзя отправить';

  @override
  String get errTooLarge => 'Файл слишком большой (до 95 МБ)';

  @override
  String get errOffline => 'Нет связи с сервером';

  @override
  String get errCouldNotSend =>
      'Не удалось отправить. Проверьте связь и попробуйте ещё раз.';

  @override
  String get errCamera => 'Камера недоступна или нет доступа';

  @override
  String get errFiles => 'Не удалось открыть «Файлы». Попробуйте ещё раз.';

  @override
  String get errMic => 'Нет доступа к микрофону';

  @override
  String get pinnedMessage => 'Закреплённое сообщение';

  @override
  String get quoteFallback => 'Ответ';

  @override
  String get you => 'Вы';

  @override
  String get chatEmptyHint =>
      'Поздоровайтесь 👋 — этот чат можете прочитать только вы двое.';

  @override
  String get errLoadMessages =>
      'Не удалось загрузить сообщения. Закройте чат и откройте снова.';

  @override
  String get typing => 'печатает…';

  @override
  String get safetyChanged => 'код проверки изменился';

  @override
  String get online => 'в сети';

  @override
  String get youDeleted => 'Вы удалили это сообщение';

  @override
  String get edited => 'изм.';

  @override
  String get messagePlaceholder => 'Сообщение';

  @override
  String get camera => 'Камера';

  @override
  String get photos => 'Фото';

  @override
  String get video => 'Видео';

  @override
  String get document => 'Документ';

  @override
  String get slideToCancel => '‹ Влево — отмена   ↑ закрепить';

  @override
  String get unreadMessages => 'Непрочитанные сообщения';

  @override
  String get editMessage => 'Редактирование';

  @override
  String selectedCount(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: 'Выбрано: $n',
      few: 'Выбрано: $n',
      one: 'Выбрано: $n',
    );
    return '$_temp0';
  }

  @override
  String get statusRead => 'Прочитано';

  @override
  String get editedA11y => ', изменено';

  @override
  String get kindPhoto => 'Фото';

  @override
  String get timerOffByMe => 'Вы выключили исчезающие сообщения';

  @override
  String get timerOffByPeer => 'Исчезающие сообщения выключены';

  @override
  String timerSetByMe(String time) {
    return 'Вы включили исчезновение сообщений через $time';
  }

  @override
  String timerSetByPeer(String time) {
    return 'Сообщения теперь исчезают через $time';
  }

  @override
  String get timeNow => 'сейчас';

  @override
  String get yesterday => 'Вчера';

  @override
  String get today => 'Сегодня';

  @override
  String get couldNotShare => 'Не удалось поделиться';

  @override
  String get showQr => 'Показать QR-код';

  @override
  String verifiedBody(String name) {
    return 'Вы проверили, что это действительно $name.';
  }

  @override
  String safetyChangedBody(String name) {
    return 'Код проверки у $name изменился — скорее всего, новый телефон. Проверьте ещё раз.';
  }

  @override
  String get notVerifiedBody =>
      'Сообщения зашифрованы в любом случае. Проверка гарантирует, что между вами никто тайно не вклинился.';

  @override
  String get neverShown => 'Никогда не показывается';

  @override
  String get perChat => 'В каждом чате';

  @override
  String get off => 'Выкл.';

  @override
  String get previewOut => 'Отлично! Только вернулись с гор 🏔';

  @override
  String get forwardTo => 'Переслать в…';

  @override
  String get noOtherChats => 'Других чатов нет';

  @override
  String get shareSendTo => 'Отправить в…';

  @override
  String get shareSearch => 'Поиск чатов';

  @override
  String get shareCaptionHint => 'Добавить подпись…';

  @override
  String get shareMessageHint => 'Сообщение';

  @override
  String get sharePickChat => 'Выберите чат';

  @override
  String get shareSend => 'Отправить';

  @override
  String shareSendCount(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: 'Отправить в $n чата',
      many: 'Отправить в $n чатов',
      few: 'Отправить в $n чата',
      one: 'Отправить в $n чат',
    );
    return '$_temp0';
  }

  @override
  String sharePhotos(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: '$n фото',
      one: 'Фото',
    );
    return '$_temp0';
  }

  @override
  String shareVideos(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: '$n видео',
      one: 'Видео',
    );
    return '$_temp0';
  }

  @override
  String shareFiles(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: '$n файла',
      many: '$n файлов',
      few: '$n файла',
      one: '$n файл',
    );
    return '$_temp0';
  }

  @override
  String get shareSent => 'Отправлено';

  @override
  String get shareNoChats => 'Чатов пока нет — сначала начните чат';

  @override
  String get shareNoAccount =>
      'Сначала войдите в Sinhron, потом поделитесь ещё раз.';

  @override
  String get shareNothing =>
      'Нечего отправить: это приложение не передало ничего, что Sinhron может открыть.';

  @override
  String get videoUnavailable => 'Видео недоступно';

  @override
  String get videoPlay => 'Воспроизвести';

  @override
  String get videoPause => 'Пауза';

  @override
  String get videoSoundOn => 'Включить звук';

  @override
  String get videoSoundOff => 'Выключить звук';

  @override
  String get viewerClose => 'Закрыть';

  @override
  String get showInChat => 'Показать в чате';

  @override
  String get forwarded => 'Переслано';

  @override
  String get couldNotForward => 'Не удалось переслать';

  @override
  String get decrypting => 'Открываем…';

  @override
  String nOfM(int n, int m) {
    return '$n из $m';
  }

  @override
  String get share => 'Поделиться';

  @override
  String get shared => 'Отправлено';

  @override
  String get saveToPhotos => 'Сохранить';

  @override
  String get savedToPhotos => 'Сохранено в «Фото»';

  @override
  String get couldNotSave => 'Не удалось сохранить';

  @override
  String get quickCheck => 'Быстрая проверка';

  @override
  String quickCheckBody(int n, int m) {
    return 'Убедимся, что слова записаны. $n из $m.';
  }

  @override
  String whichWord(int n) {
    return 'Какое слово под номером $n?';
  }

  @override
  String wrongWord(int n) {
    return 'Не то — посмотрите ещё раз слово №$n на бумаге.';
  }

  @override
  String get showWordsAgain => 'Показать слова ещё раз';

  @override
  String get saveAccessTitle => 'Сохраните доступ к аккаунту';

  @override
  String get saveAccessBody =>
      'Ваш аккаунт — это 24 секретных слова. Если телефон потеряется, по ним вы вернёте аккаунт на новом. У нас этих слов нет — сохраните их там, где не потеряете.';

  @override
  String get saveToPasswordsIos => 'Сохранить в связку ключей iCloud';

  @override
  String get saveToPasswordsAndroid => 'Сохранить в менеджер паролей';

  @override
  String get savePasswordsHintIos =>
      'Одно нажатие. Прочитать их может только Sinhron — в приложении «Пароли» их нет, и ни один сайт их не запросит. Со связкой ключей iCloud они перейдут на новый iPhone.';

  @override
  String get savePasswordsHintAndroid =>
      'Одно нажатие. Google зашифрует их и перенесёт на новый телефон вместе с Google-аккаунтом.';

  @override
  String get passwordsFailed =>
      'Не получилось сохранить в менеджер паролей. Попробуйте ещё раз или запишите слова.';

  @override
  String get writeWordsAction => 'Записать слова';

  @override
  String get writeWordsRowHint => 'На бумаге или листом для печати';

  @override
  String get saveLater => 'Позже';

  @override
  String get saveLaterHint =>
      'Пока слова будут только на этом телефоне. Напомним в Настройках.';

  @override
  String get writeWordsTitle => 'Запишите 24 слова';

  @override
  String get writeWordsBody =>
      'По порядку, на бумаге. Храните как паспорт: кто прочтёт эти слова, сможет открыть ваш аккаунт.';

  @override
  String get screenshotNote =>
      'Снимок экрана — не лучшее место: он уходит в облако вместе с фото.';

  @override
  String get wordsWritten => 'Я записал(а)';

  @override
  String get sheetAction => 'Лист восстановления для печати';

  @override
  String get sheetTitle => 'Sinhron — секретные слова';

  @override
  String get sheetHowTitle => 'Как вернуть аккаунт';

  @override
  String get sheetHowBody =>
      'Установите Sinhron на новый телефон → «Войти по секретным словам» → наведите камеру на этот код или введите 24 слова по порядку.';

  @override
  String get sheetWarning =>
      'Кто видит эти слова — тот владеет аккаунтом. Распечатайте лист и удалите файл. Не отправляйте его никому и не храните его фото в облаке.';

  @override
  String get sheetScan => 'Сканировать лист восстановления';

  @override
  String get sheetNotWords => 'Этот код — не лист восстановления.';

  @override
  String get pasteFromPasswordsIos => 'Вставить из связки ключей iCloud';

  @override
  String get pasteFromPasswordsAndroid => 'Вставить из менеджера паролей';

  @override
  String get reminderBody =>
      'Секретные слова пока только на этом телефоне. Сохраните их, чтобы не потерять аккаунт.';

  @override
  String get reminderSave => 'Сохранить';

  @override
  String get wordsNotSaved => 'Не сохранены';

  @override
  String get accessNotSavedTitle => 'Доступ не сохранён';

  @override
  String get accessNotSavedBody =>
      'Слова пока только на этом телефоне. Если с ним что-то случится, аккаунт не вернуть.';

  @override
  String get accessSaveSection => 'Сохранить';

  @override
  String get accessSaveFooter =>
      'После сохранения слова удаляются с телефона — они будут там, куда вы их сохранили.';

  @override
  String get accessSavedTitle => 'Доступ сохранён';

  @override
  String accessSavedPasswordsIos(String date) {
    return 'В «Паролях» · $date, как пароль сайта — сайт может его запросить. Перенесите их ниже.';
  }

  @override
  String accessSavedKeychainIos(String date) {
    return 'В связке ключей iCloud · $date. Читает их только Sinhron; на новый iPhone перейдут, если включена связка ключей iCloud.';
  }

  @override
  String get moveToKeychain => 'Перенести в связку ключей iCloud';

  @override
  String get moveToKeychainFooter =>
      'Выберите запись Sinhron: слова перейдут в связку ключей iCloud, а старая запись в «Паролях» удалится.';

  @override
  String accessSavedPasswordsAndroid(String date) {
    return 'В менеджере паролей · $date. Перенесутся на новый телефон вместе с Google-аккаунтом.';
  }

  @override
  String accessSavedPaper(String date) {
    return 'Записаны на бумаге · $date. Храните её как паспорт.';
  }

  @override
  String accessSavedSheet(String date) {
    return 'Лист восстановления · $date. Распечатайте его и удалите файл.';
  }

  @override
  String accessSavedChecked(String date) {
    return 'Проверены · $date. Слова у вас верные.';
  }

  @override
  String get accessSavedDone => 'Сохранено';

  @override
  String get phraseStatusAllWords => '24 слова';

  @override
  String get secondDeviceSection => 'Второе устройство';

  @override
  String secondDeviceCount(int n) {
    return 'Другие устройства: $n';
  }

  @override
  String get secondDeviceLink => 'Привязать второе устройство';

  @override
  String get secondDeviceYes =>
      'Если с этим телефоном что-то случится, переписка останется на другом устройстве. Но добавить новый телефон всё равно можно только по секретным словам.';

  @override
  String get secondDeviceNo =>
      'Второе устройство (планшет, другой телефон) сохранит переписку, если этот телефон потеряется. Слова оно не заменяет: новый телефон добавляется по ним.';

  @override
  String get checkWordsTitle => 'Проверка слов';

  @override
  String get checkWordsBody =>
      'Введите 24 секретных слова — приложение сверит их с этим аккаунтом. Они не сохраняются.';

  @override
  String get checkWordsAction => 'Проверить';

  @override
  String get wordsMatch => 'Верно — это ваши слова';

  @override
  String get wordsDontMatch => 'Это не слова этого аккаунта';

  @override
  String verifyTitle(String name) {
    return 'Проверка: $name';
  }

  @override
  String get verifyNotYet =>
      'Этот чат пока нельзя проверить — сначала отправьте сообщение.';

  @override
  String get showNumber => 'Показать число';

  @override
  String verifyExplain(String name) {
    return 'Сравните это число с числом на телефоне $name — при встрече или по звонку. Если совпадает, между вами никого нет и чат читаете только вы двое.';
  }

  @override
  String get clearVerification => 'Снять отметку';

  @override
  String get markVerified => 'Отметить как проверенный';

  @override
  String get verifiedTitle => 'Проверен';

  @override
  String get safetyChangedTitle => 'Код проверки изменился';

  @override
  String get notVerifiedTitle => 'Ещё не проверен';

  @override
  String get unlockReason => 'Разблокировать Sinhron';

  @override
  String get appLocked => 'Sinhron заблокирован';

  @override
  String get tapToUnlock => 'Нажмите, чтобы разблокировать по Face ID или коду';

  @override
  String get setPasscodeFirst =>
      'Сначала задайте код-пароль на iPhone — блокировка использует его.';

  @override
  String get turnOnAppLock => 'Включить блокировку';

  @override
  String get lockAgain => 'Блокировать снова';

  @override
  String get appLockTitle => 'Блокировка приложения';

  @override
  String get lockSection => 'Блокировка';

  @override
  String get appLockFooter =>
      'Sinhron будет спрашивать Face ID или код-пароль iPhone при открытии. Чаты зашифрованы в любом случае.';

  @override
  String get appLockToggle => 'Блокировка';

  @override
  String get appSwitcher => 'Переключатель приложений';

  @override
  String get appSwitcherFooter =>
      'Закрывает чаты размытием, когда вы переключаетесь между приложениями, — их не видно в переключателе.';

  @override
  String get hideInSwitcher => 'Скрывать чаты в переключателе';

  @override
  String get privacyTitle => 'Конфиденциальность';

  @override
  String get whatOthersSee => 'Что видят другие';

  @override
  String get whatOthersSeeFooter =>
      'Если выключить отметки «Прочитано» или «печатает», вы тоже не будете их видеть — честно в обе стороны. «В сети» и «был(а)» видят только ваши контакты — люди, с которыми у вас личный чат, — и только пока это включено. Если выключить, они забудут, когда видели вас последний раз.';

  @override
  String get readReceipts => 'Отметки «Прочитано»';

  @override
  String get typingIndicators => '«Печатает…»';

  @override
  String get onlineStatus => 'Статус «в сети»';

  @override
  String get showOnline => 'Показывать, что я в сети';

  @override
  String get onlyContacts => 'Только контактам';

  @override
  String get lastSeenJustNow => 'был(а) только что';

  @override
  String lastSeenMinutes(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: 'был(а) $n минуты назад',
      many: 'был(а) $n минут назад',
      few: 'был(а) $n минуты назад',
      one: 'был(а) $n минуту назад',
    );
    return '$_temp0';
  }

  @override
  String lastSeenToday(String time) {
    return 'был(а) сегодня в $time';
  }

  @override
  String lastSeenYesterday(String time) {
    return 'был(а) вчера в $time';
  }

  @override
  String lastSeenDate(String date) {
    return 'был(а) $date';
  }

  @override
  String get disappearingMessages => 'Исчезающие сообщения';

  @override
  String get disappearingFooter =>
      'Включается в каждом чате: нажмите и удерживайте имя вверху. Сообщения удалятся на обоих телефонах — и текст, и фото.';

  @override
  String get timer => 'Таймер';

  @override
  String get links => 'Ссылки';

  @override
  String get linksFooter =>
      'Картинку и заголовок ссылки загружает ваш телефон, когда вы её отправляете: сайт узнаёт, что её открыли с вашего телефона, но не знает, кому вы пишете. По умолчанию выключено.';

  @override
  String get linkPreviews => 'Превью ссылок';

  @override
  String get thisDevice => 'Это устройство';

  @override
  String get on => 'Вкл.';

  @override
  String get e2eTitle => 'Зашифровано';

  @override
  String get e2eAlways => 'Всегда включено. Это не настройка.';

  @override
  String get e2eBody =>
      'Ваши сообщения, звонки и файлы можно прочитать только на ваших устройствах и у собеседников. Сервер видит лишь зашифрованные данные и время доставки — не содержимое и не круг общения.';

  @override
  String get chipKeys => 'У каждого сообщения свой ключ';

  @override
  String get chipOld => 'Старые сообщения в безопасности';

  @override
  String get chipHeal => 'Защита сама восстанавливается после взлома';

  @override
  String get appearance => 'Оформление';

  @override
  String get theme => 'Тема';

  @override
  String get accentColour => 'Цвет акцента';

  @override
  String get chatWallpaper => 'Обои чатов';

  @override
  String get wallpaperFooter => 'Ваше фото хранится только на этом устройстве.';

  @override
  String get previewIn => 'Привет! Как дела? 👋';

  @override
  String get unavailable => 'Недоступно';

  @override
  String get file => 'Файл';

  @override
  String get documentUnavailable => 'Документ недоступен';

  @override
  String get couldNotOpen => 'Не удалось открыть — нажмите ещё раз';

  @override
  String get photoUnavailable => 'Фото недоступно';

  @override
  String get whatPhoto => 'фото';

  @override
  String get whatVoice => 'голосовое';

  @override
  String get whatVideo => 'видео';

  @override
  String notSentRetry(String what) {
    return 'Не отправлено: $what — нажмите, чтобы повторить';
  }

  @override
  String sendingPercent(String what, int p) {
    return 'Отправляется $what… $p%';
  }

  @override
  String preparing(String what) {
    return 'Готовим $what…';
  }

  @override
  String sending(String what) {
    return 'Отправляется $what…';
  }

  @override
  String get lockImmediately => 'Сразу';

  @override
  String lockAfterMinutes(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: 'Через $n минуты',
      many: 'Через $n минут',
      few: 'Через $n минуты',
      one: 'Через $n минуту',
    );
    return '$_temp0';
  }

  @override
  String get lockAfterHour => 'Через 1 час';

  @override
  String get themeSystem => 'Как в системе';

  @override
  String get themeLight => 'Светлая';

  @override
  String get themeDark => 'Тёмная';

  @override
  String get themeOled => 'Чёрная (OLED)';

  @override
  String get wallNone => 'Нет';

  @override
  String get wallDawn => 'Рассвет';

  @override
  String get wallMist => 'Туман';

  @override
  String get wallDusk => 'Сумерки';

  @override
  String get wallDots => 'Точки';

  @override
  String get wallWaves => 'Волны';

  @override
  String get wallPhoto => 'Фото';

  @override
  String get yourName => 'Ваше имя';

  @override
  String get keyNotCreated => 'Адрес ещё не готов';

  @override
  String keyFingerprint(String fp) {
    return 'Адрес $fp';
  }

  @override
  String get language => 'Язык';

  @override
  String get langSystem => 'Как на телефоне';

  @override
  String get langEn => 'English';

  @override
  String get langRu => 'Русский';

  @override
  String get privacySection => 'Приватность';

  @override
  String get privacySectionFooter =>
      'Переписка всегда зашифрована — читаете её только вы и собеседники. Эти настройки решают, что о вас видят другие люди и сервер.';

  @override
  String get review => 'Проверить';

  @override
  String get linkedDevices => 'Устройства';

  @override
  String get accountKey => 'Секретные слова';

  @override
  String get notifications => 'Уведомления';

  @override
  String get notificationsFooter =>
      'Когда Sinhron закрыт, iPhone показывает только «Новое сообщение» — сервер не может читать сообщения.';

  @override
  String get soundsVibration => 'Звуки и вибрация';

  @override
  String get textSize => 'Размер текста';

  @override
  String get asInIphone => 'Как в настройках iPhone';

  @override
  String get wallpaper => 'Обои';

  @override
  String get storage => 'Хранилище';

  @override
  String get server => 'Сервер';

  @override
  String get serverFooter =>
      'Сервер — это компьютер, через который сообщения доходят до собеседников. Его владелец видит, когда они доставляются, но прочитать их не может.';

  @override
  String get notConnected => 'Нет подключения';

  @override
  String get about => 'О приложении';

  @override
  String updateAvailableTitle(String version) {
    return 'Доступно обновление $version';
  }

  @override
  String get updateAvailableBody =>
      'Скачается прямо здесь, потом Android попросит нажать «Установить». Переписки и ключи останутся.';

  @override
  String get updateAction => 'Обновить';

  @override
  String updateDownloading(int percent) {
    return 'Скачиваю обновление… $percent%';
  }

  @override
  String get updateReadyTitle => 'Обновление скачано';

  @override
  String get updateReadyBody =>
      'Нажмите «Установить» — Android спросит ещё раз.';

  @override
  String get updateInstall => 'Установить';

  @override
  String get updateFailedOffline =>
      'Не получилось скачать обновление. Проверьте интернет и попробуйте ещё раз.';

  @override
  String get updateFailedBadFile =>
      'Файл обновления не прошёл проверку безопасности, устанавливать его нельзя. Попробуйте позже.';

  @override
  String get updateFailedInstaller =>
      'Android не открыл установку. Попробуйте ещё раз.';

  @override
  String get updateRetry => 'Повторить';

  @override
  String get updateLater => 'Позже';

  @override
  String get updateCheck => 'Проверить обновления';

  @override
  String get updateCheckHint => 'Новые версии приходят с нашего сервера';

  @override
  String get updateChecking => 'Проверяю…';

  @override
  String get updateUpToDate => 'У вас последняя версия';

  @override
  String get updateOffline => 'Нет связи с сервером — попробуйте позже';

  @override
  String updateNewVersion(String version) {
    return 'Есть $version';
  }

  @override
  String get updatePermissionExplain =>
      'Сейчас Android спросит, можно ли Sinhron устанавливать приложения. Нажмите «Настройки», включите «Разрешить из этого источника» и вернитесь назад — установка продолжится, затем нажмите «Установить». Так спрашивают только в первый раз.';

  @override
  String get updateContinue => 'Продолжить';

  @override
  String get clipboardClears => 'Буфер обмена очистится через 60 секунд';

  @override
  String get copied => 'Скопировано';

  @override
  String get copyPhrase => 'Скопировать слова';

  @override
  String get tagline => 'Сообщения, которые остаются между вами.';

  @override
  String get getStarted => 'Начать';

  @override
  String get linkDevice => 'Подключить устройство';

  @override
  String get restoreFromKey => 'Войти по секретным словам →';

  @override
  String get pickServer => 'Выберите сервер';

  @override
  String get pickServerBody =>
      'Сервер — это компьютер, через который сообщения доходят до собеседников. Подойдёт сервер вашей команды, друга или ваш собственный. Прочитать ваши сообщения он не может.';

  @override
  String get serverHowToGet =>
      'Адрес сервера даёт тот, кто его настроил. Введите его или отсканируйте QR-код, который вам показали.';

  @override
  String get serverScanQr => 'Сканировать QR-код сервера';

  @override
  String get serverInvalid =>
      'Это не похоже на адрес сервера — например, sinhron.example.com.';

  @override
  String get serverNotSinhron =>
      'По этому адресу что-то отвечает, но это не сервер Sinhron.';

  @override
  String get serverUnreachable =>
      'Сервер не отвечает. Проверьте адрес и интернет.';

  @override
  String get serverNotSaved =>
      'Не удалось сохранить на телефоне — хранилище приложения не открылось. Закройте приложение и откройте снова.';

  @override
  String get serverContinueAnyway => 'Всё равно продолжить';

  @override
  String get pairNoServer => 'Сначала укажите сервер — вернитесь на шаг назад.';

  @override
  String get inviteToken => 'Код приглашения';

  @override
  String get pasteInvite => 'вставьте код приглашения';

  @override
  String get inviteAuto => 'Заполняется из ссылки-приглашения.';

  @override
  String get continueBtn => 'Продолжить';

  @override
  String get yourProfile => 'Ваш профиль';

  @override
  String get profileBody =>
      'Имя, которое увидят собеседники. Его можно поменять в любой момент.';

  @override
  String get nameLabel => 'Имя';

  @override
  String get nameHint => 'Как вас видят собеседники';

  @override
  String get settingUp => 'Настраиваем устройство';

  @override
  String get inApp => 'В приложении';

  @override
  String get vibration => 'Вибрация';

  @override
  String get inChatSounds => 'Звуки в чате';

  @override
  String get pushNotifications => 'Уведомления';

  @override
  String get comingSoon => 'В версии App Store';

  @override
  String setupConnecting(String host) {
    return 'Подключаемся к $host';
  }

  @override
  String get setupIdentity => 'Проверяем этот телефон';

  @override
  String get setupGroups => 'Подключаем ваши группы';

  @override
  String get setupContacts => 'Готовим чаты';

  @override
  String get mediaLoadError => 'Не удалось загрузить медиа';

  @override
  String get noVoiceYet => 'Голосовых пока нет';

  @override
  String get noLinksYet => 'Ссылок пока нет';

  @override
  String get sharedMediaMedia => 'Медиа';

  @override
  String get sharedMediaFiles => 'Файлы';

  @override
  String get noMediaYet => 'Фото и видео пока нет';

  @override
  String get noFilesYet => 'Файлов пока нет';

  @override
  String get searchContacts => 'Поиск контактов';

  @override
  String get contactsEmpty =>
      'Контактов пока нет. Добавьте человека по QR-коду, ссылке-приглашению или адресу — он останется здесь, даже если удалить чат.';

  @override
  String get recent => 'Недавние';

  @override
  String get contactsFooter =>
      'Контакты хранятся только на этом телефоне — сервер не знает, с кем вы общаетесь. Начните чат по QR-коду или адресу.';

  @override
  String noContactNamed(String q) {
    return 'Нет контакта «$q»';
  }

  @override
  String get noContactHint =>
      'Попробуйте другое имя или пригласите по QR-коду.';

  @override
  String get newChat => 'Новый чат';

  @override
  String get newGroup => 'Новая группа';

  @override
  String get inviteByQr => 'Пригласить по QR';

  @override
  String get scanQr => 'Сканировать QR';

  @override
  String get pasteKey => 'Вставить адрес';

  @override
  String get pasteFromClipboard => 'Вставить';

  @override
  String pasteKeyCount(int count) {
    return '$count из 64 знаков';
  }

  @override
  String get pasteKeyReady => 'Адрес верный';

  @override
  String get startEncrypted => 'Начать зашифрованный чат';

  @override
  String get pasteKeyHint =>
      'Вставьте адрес собеседника — 64 знака. Он найдёт его у себя: Мой профиль → Скопировать адрес. Чтобы получить приглашение, он должен быть в сети.';

  @override
  String get keyHint => '64 знака';

  @override
  String get sendingInvite => 'Отправляем приглашение…';

  @override
  String get startChat => 'Начать чат';

  @override
  String get noEmailV => 'мы её не спрашиваем';

  @override
  String get skip => 'Пропустить';

  @override
  String get welcome => 'Добро пожаловать';

  @override
  String get privateByDefault => 'Приватно по умолчанию.';

  @override
  String get splash1Body =>
      'Sinhron шифрует всё с первого сообщения. Ваши сообщения, звонки и файлы можно прочитать только на ваших устройствах.';

  @override
  String get splash2Eyebrow => 'Ничего лишнего';

  @override
  String get splash2Title => 'Без почты, телефона и пароля.';

  @override
  String get noEmail => 'Без почты';

  @override
  String get noPhone => 'Без номера телефона';

  @override
  String get noPhoneV => 'вас добавляют по QR-коду или ссылке';

  @override
  String get noPassword => 'Без пароля';

  @override
  String get noPasswordV => 'вместо него — 24 секретных слова';

  @override
  String get ownKey => 'Слова есть только у вас';

  @override
  String get ownKeyV => 'потеряли слова — потеряли аккаунт';

  @override
  String get selfHosted => 'Свой сервер';

  @override
  String get serverTrust =>
      'Sinhron работает на сервере, которому вы доверяете.';

  @override
  String get serverRun => 'Его можно поднять самим, в команде или компании. ';

  @override
  String get serverData =>
      '. Данные хранятся там и больше нигде — ни у нас, ни у кого-то ещё.';

  @override
  String get a11ySearch => 'Поиск';

  @override
  String a11yUnread(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: '$n непрочитанного',
      many: '$n непрочитанных',
      few: '$n непрочитанных',
      one: '$n непрочитанное',
    );
    return '$_temp0';
  }

  @override
  String get a11yBack => 'Назад';

  @override
  String get a11yVideoCall => 'Видеозвонок';

  @override
  String get a11yAttach => 'Прикрепить';

  @override
  String get a11yCloseAttach => 'Закрыть вложения';

  @override
  String get cancelSending => 'Отменить отправку';

  @override
  String get splitPickChat => 'Выберите чат';

  @override
  String get splitPickSetting => 'Выберите раздел';

  @override
  String get splitPickContact => 'Выберите контакт';

  @override
  String get splitPickCall => 'Выберите звонок — откроется его чат';

  @override
  String get a11yOpenPhoto => 'Открыть фото';

  @override
  String typingOne(String name) {
    return '$name печатает…';
  }

  @override
  String typingTwo(String a, String b) {
    return '$a и $b печатают…';
  }

  @override
  String typingMany(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count человек печатают…',
      few: '$count человека печатают…',
      one: '$count человек печатает…',
    );
    return '$_temp0';
  }

  @override
  String blockedChatNote(String name) {
    return 'Вы заблокировали $name: его сообщения и звонки не показываются, а ваше фото и «в сети» он больше не видит.';
  }

  @override
  String get a11ySend => 'Отправить';

  @override
  String get a11yRecord =>
      'Удерживайте — голосовое сообщение. Нажмите — переключить на видео';

  @override
  String get a11yRecordVideo =>
      'Удерживайте — видеосообщение. Нажмите — переключить на голосовое';

  @override
  String get videoMessage => 'Видеосообщение';

  @override
  String get videoNoteCropFailed =>
      'Не получилось обрезать видео в кружок, поэтому оно не отправлено. Запишите ещё раз.';

  @override
  String get whatVideoNote => 'видеосообщение';

  @override
  String get holdToRecordVoice => 'Удерживайте для голосового, нажмите — видео';

  @override
  String get holdToRecordVideo =>
      'Удерживайте для видеосообщения, нажмите — голос';

  @override
  String get errCameraMic =>
      'Разрешите камеру и микрофон в Настройках, чтобы записывать видеосообщения';

  @override
  String a11yVideoNotePlay(String duration) {
    return 'Видеосообщение, $duration. Нажмите, чтобы слушать со звуком';
  }

  @override
  String get a11yVoiceSeek =>
      'Позиция воспроизведения. Проведите, чтобы перемотать';

  @override
  String get a11yEmoji => 'Эмодзи';

  @override
  String a11yMessageFrom(String name, String time) {
    return '$name, $time';
  }

  @override
  String a11yReplyTo(String text) {
    return 'ответ на: $text';
  }

  @override
  String a11yReactions(String list) {
    return 'реакции: $list';
  }

  @override
  String get a11yMessageHint => 'Дважды коснитесь и удерживайте для действий';

  @override
  String get a11yPinned => 'закреплён';

  @override
  String get a11yMuted => 'без звука';

  @override
  String a11yDraft(String text) {
    return 'черновик: $text';
  }

  @override
  String get a11yReact => 'Поставить сердце';

  @override
  String get bannerNewMessage => 'Новое сообщение';

  @override
  String get notificationReply => 'Ответить';

  @override
  String get notificationReplySend => 'Отправить';

  @override
  String get notificationReplyPlaceholder => 'Сообщение';

  @override
  String get notificationReplyLater =>
      'Ответ уйдёт, как только Sinhron подключится';

  @override
  String get notificationReplyOnOpen =>
      'Ответ уйдёт, когда вы откроете Sinhron';

  @override
  String get notificationReplyFailed => 'Ответ не отправлен — откройте чат';

  @override
  String get notificationNewRequest => 'Новый запрос на переписку';

  @override
  String get bannerHint => 'Открывает чат';

  @override
  String get inAppBanners => 'Баннеры в приложении';

  @override
  String get bannerPreview => 'Показывать текст';

  @override
  String get bannersFooter =>
      'Когда приходит сообщение в другой чат, сверху появляется баннер. Нажмите — откроется чат, смахните вверх — скроется. Чаты без звука и в архиве молчат.';

  @override
  String get iconBadge => 'Счётчик на иконке';

  @override
  String get unlockTitle => 'Разблокируйте Sinhron';

  @override
  String get unlockBody =>
      'Чаты на этом телефоне зашифрованы. Введите 24 секретных слова, чтобы открыть их.';

  @override
  String get reconnectTitle => 'Подключите аккаунт снова';

  @override
  String get reconnectBody =>
      'Чтобы снова подключиться к серверу, введите 24 секретных слова. На этом телефоне это нужно сделать один раз.';

  @override
  String get unlockHint => '24 слова через пробел';

  @override
  String get unlockAction => 'Разблокировать';

  @override
  String get unlockPhraseNote =>
      'Слова не покидают телефон и не сохраняются — телефон запомнит только сделанный из них ключ, в защищённой связке ключей iPhone.';

  @override
  String get unlockInvalidPhrase =>
      'Это не похоже на секретные слова — проверьте слова и их порядок.';

  @override
  String get unlockWrongPhrase =>
      'Эти слова не подходят к аккаунту на этом телефоне.';

  @override
  String get eraseAndStartOver => 'Стереть и начать заново';

  @override
  String get deviceRemovedTitle => 'Это устройство вышло из аккаунта';

  @override
  String get deviceRemovedBody =>
      'Его отключили на другом вашем устройстве. Чаты здесь больше не обновляются, сообщения и звонки сюда не приходят. Выйдите — копия на этом устройстве сотрётся, переписка останется на других ваших устройствах.';

  @override
  String get deviceRemovedAction => 'Выйти';

  @override
  String get eraseConfirmTitle =>
      'Все чаты на этом телефоне будут удалены. Это нельзя отменить.';

  @override
  String get eraseConfirmAction => 'Стереть всё';

  @override
  String get netConnected => 'Подключено';

  @override
  String get netConnecting => 'Подключение…';

  @override
  String get netOffline => 'Нет связи';

  @override
  String get reconnect => 'Переподключиться';

  @override
  String get connection => 'Соединение';

  @override
  String navNewChatName(String id) {
    return 'Чат $id';
  }

  @override
  String get chatDraftPrefix => 'Черновик: ';

  @override
  String get phraseStrengthValue => 'Очень высокая';

  @override
  String get photoCouldNotUse =>
      'Не получилось взять это фото. Проверьте доступ к фото: Настройки телефона → Sinhron → Фото.';

  @override
  String get backupSearching => 'Ищу копию…';

  @override
  String get errRecordingFailed => 'Запись не получилась — попробуйте ещё раз';

  @override
  String get linkCouldNotOpen => 'Не получилось открыть ссылку';

  @override
  String get newChatPlaceholder => 'Новый чат';

  @override
  String get newGroupPlaceholder => 'Новая группа';

  @override
  String get memberUnnamed => 'Участник';

  @override
  String get appLockOffNoPasscode =>
      'Блокировка приложения выключена: на телефоне больше нет код-пароля и Face ID. Включить снова — Настройки → Блокировка приложения.';

  @override
  String get unlockFailed =>
      'Не получилось открыть — дело не в словах. Попробуйте ещё раз через минуту.';

  @override
  String get navErrKeyAlreadyInChat =>
      'Этот адрес уже есть в чате — скорее всего, это ваш собственный. Вставьте адрес собеседника, а не свой.';

  @override
  String get navErrNoKeyPackage =>
      'Пока не получается пригласить собеседника: его телефон ещё не закончил настройку. Попросите его открыть Sinhron и подождать, пока всё загрузится, затем попробуйте снова.';

  @override
  String get navErrRateLimited =>
      'Слишком много запросов к серверу. Подождите минуту и попробуйте снова.';

  @override
  String get navErrServerUnreachable =>
      'Не удаётся связаться с сервером. Проверьте интернет — Sinhron переподключится сам.';

  @override
  String get navErrBadKeyFormat =>
      'Адрес — это ровно 64 знака: цифры и буквы a–f. Проверьте, что скопировали его целиком.';

  @override
  String netGroupDefaultName(String id) {
    return 'Группа $id';
  }

  @override
  String get netAddedToChat => 'Вас добавили в этот чат';

  @override
  String get netUnsupportedMessage =>
      'Сообщение не поддерживается — обновите Sinhron, чтобы его увидеть';

  @override
  String get chatsEncryptedStarted => 'Зашифрованный чат создан';

  @override
  String get callKitPeerName => 'Звонок в Sinhron';

  @override
  String get callErrMic =>
      'Нет доступа к микрофону. Разрешите его: Настройки → Sinhron → Микрофон.';

  @override
  String get callErrCamera =>
      'Нет доступа к камере. Разрешите её: Настройки → Sinhron → Камера.';

  @override
  String get callErrFailed =>
      'Не удалось начать звонок. Проверьте интернет и попробуйте ещё раз.';

  @override
  String get callsMissed => 'Пропущенные';

  @override
  String get callsEarlier => 'Ранее';

  @override
  String get callsAudio => 'аудио';

  @override
  String get callsVideo => 'видео';

  @override
  String callsMinutes(int n) {
    return '$n мин';
  }

  @override
  String get callsNoAnswer => 'Нет ответа';

  @override
  String get callsDeclined => 'Отклонён';

  @override
  String get callsEmpty =>
      'Звонков пока нет. Позвонить можно из чата — кнопка с трубкой вверху.';

  @override
  String get callIncomingVideo => 'входящий видеозвонок';

  @override
  String get callIncomingAudio => 'входящий звонок Sinhron';

  @override
  String get callCalling => 'Вызов…';

  @override
  String get callRinging => 'Звонит…';

  @override
  String get callOngoing => 'Идёт звонок';

  @override
  String get callOngoingVideo => 'Идёт видеозвонок';

  @override
  String get callJoin => 'Присоединиться';

  @override
  String get callJoinFailed =>
      'Не удалось присоединиться — звонок уже закончился.';

  @override
  String get callWaitingForPeople => 'Ждём участников…';

  @override
  String get callDecline => 'Отклонить';

  @override
  String get callAccept => 'Принять';

  @override
  String get callUnmute => 'Вкл. звук';

  @override
  String get callFlipCamera => 'Перевернуть';

  @override
  String get callMute => 'Выкл. звук';

  @override
  String get callSpeaker => 'Динамик';

  @override
  String get callEnd => 'Завершить';

  @override
  String callEnded(String duration) {
    return 'Звонок завершён · $duration';
  }

  @override
  String get callReconnecting => 'Переподключение…';

  @override
  String get callLinkQuality => 'Качество связи';

  @override
  String get callWeakLink => 'Слабая связь';

  @override
  String get callWeakLinkPeer => 'Слабая связь у собеседника';

  @override
  String get callAutoAudioOnly =>
      'Слабая связь — камера выключена, чтобы не пропадал звук';

  @override
  String get callBarTapToReturn => 'Вернуться';

  @override
  String get contactsFavourites => 'Избранное';

  @override
  String get contactsVerified => 'Проверенные';

  @override
  String get contactsInvite => 'Пригласить друзей';

  @override
  String get contactsInviteHint =>
      'Отправьте ссылку — одно касание, и вы у них в контактах';

  @override
  String get contactAdd => 'Добавить в контакты';

  @override
  String get contactEditName => 'Изменить имя';

  @override
  String get contactNameOnlyYou => 'Видно только вам';

  @override
  String contactNameRestore(String name) {
    return 'Вернуть имя «$name»';
  }

  @override
  String get contactRemove => 'Удалить из контактов';

  @override
  String contactRemoveConfirm(String name) {
    return 'Удалить $name из контактов? Переписка останется.';
  }

  @override
  String get contactFavouriteAdd => 'Добавить в избранное';

  @override
  String get contactFavouriteRemove => 'Убрать из избранного';

  @override
  String get contactKey => 'Ключ';

  @override
  String get profileAboutHint =>
      'Это видят в вашем профиле те, с кем вы переписываетесь';

  @override
  String contactsAllCount(int n) {
    return 'Все контакты · $n';
  }

  @override
  String get contactIdentityVerified => 'Проверен(а) вами';

  @override
  String get contactAbout => 'О себе';

  @override
  String get contactIdentity => 'Проверка';

  @override
  String get contactMessage => 'Написать';

  @override
  String get contactMediaLinksDocs => 'Медиа, ссылки и документы';

  @override
  String contactGroupsInCommon(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: '$n общей группы',
      many: '$n общих групп',
      few: '$n общие группы',
      one: '$n общая группа',
    );
    return '$_temp0';
  }

  @override
  String contactGroupMembers(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: '$n участника',
      many: '$n участников',
      few: '$n участника',
      one: '$n участник',
    );
    return '$_temp0';
  }

  @override
  String get newGroupPickOne => 'Выберите хотя бы один контакт';

  @override
  String newGroupNext(int n) {
    return 'Далее · выбрано: $n';
  }

  @override
  String get newGroupAllContacts => 'Все контакты';

  @override
  String get newGroupCreate => 'Создать группу';

  @override
  String get newGroupName => 'Название группы';

  @override
  String newGroupMembersCount(int n) {
    return 'Участники · $n';
  }

  @override
  String get groupInfoAdmin => 'Админ';

  @override
  String get newGroupFooter =>
      'Участники получают группу прямо с вашего телефона в зашифрованном виде. Сервер только передаёт её — он не видит, кто в группе и о чём там говорят.';

  @override
  String newGroupAddCta(int n) {
    return 'Добавить · выбрано: $n';
  }

  @override
  String get newGroupNoContacts =>
      'Пока некого добавить. Сначала начните личный чат с человеком — потом его можно позвать в группу.';

  @override
  String get newGroupNoOneToAdd =>
      'Все, с кем вы переписываетесь, уже в этой группе.';

  @override
  String get newGroupCreating => 'Создаём группу…';

  @override
  String get groupInfoMembers => 'Участники';

  @override
  String get groupInfoMediaFiles => 'Медиа и файлы';

  @override
  String get groupInfoAddMember => 'Добавить участника';

  @override
  String groupInfoMemberYou(String name) {
    return '$name (вы)';
  }

  @override
  String get blockedTitle => 'Заблокированные';

  @override
  String blockedCount(int n) {
    return 'Заблокировано: $n';
  }

  @override
  String get blockedUnblock => 'Разблокировать';

  @override
  String get blockedWhatItDoes => 'Что даёт блокировка';

  @override
  String get blockedNoPresence =>
      'Заблокированный никогда не видит, что вы в сети.';

  @override
  String get blockedMessagesDiscarded =>
      'Сообщения и реакции от этого человека отбрасываются на этом устройстве — ему об этом не сообщается.';

  @override
  String get blockedCallsRejected =>
      'Звонки в вашем личном чате с этим человеком сбрасываются без звонка.';

  @override
  String get blockedNoGroups =>
      'В общих группах сообщения этого человека скрыты от вас, сама группа не меняется.';

  @override
  String get blockedLocalFooter =>
      'Список хранится только на этом телефоне. Сервер не знает, кого вы заблокировали.';

  @override
  String get blockedEmptyTitle => 'Заблокированных нет';

  @override
  String get blockedEmptyHint =>
      'Заблокировать человека можно на экране «О чате». Блокировка действует только на этом устройстве.';

  @override
  String get sharedMediaTitle => 'Медиа и файлы';

  @override
  String get sharedMediaDocuments => 'Документы';

  @override
  String get sharedMediaVoice => 'Голосовые';

  @override
  String get inviteLandingTitle => 'Вас пригласили на сервер Sinhron';

  @override
  String get inviteLandingBody =>
      'Sinhron — приватный мессенджер, который работает на сервере, которому вы доверяете. Ниже — сервер, к которому вы подключитесь, и тот, кто вас пригласил.';

  @override
  String get inviteStepName => 'Выберите имя';

  @override
  String get inviteStepNameBody => 'Без почты, телефона и пароля';

  @override
  String get inviteStepPhrase => 'Запишите 24 секретных слова';

  @override
  String get inviteStepPhraseBody => 'Только с ними можно восстановить аккаунт';

  @override
  String get inviteStepDone => 'Всё готово';

  @override
  String inviteStepDoneBody(String name) {
    return '$name станет первым контактом в вашем списке';
  }

  @override
  String get inviteAccept => 'Принять и настроить';

  @override
  String get inviteHaveAccount => 'У меня уже есть аккаунт';

  @override
  String get inviteEyebrow => 'ПРИГЛАШЕНИЕ';

  @override
  String inviteReachable(int ms) {
    return 'Доступен · $ms мс';
  }

  @override
  String get inviteInvitedBy => 'Пригласил(а)';

  @override
  String inviteExpiresInHours(int n) {
    return 'Истекает через $n ч';
  }

  @override
  String get inviteNextSteps => 'ЧТО ДАЛЬШЕ';

  @override
  String get legalYourIdentity => 'Ваш аккаунт';

  @override
  String get safetyNumberTitle => 'Проверка собеседника';

  @override
  String get serverStatus => 'Статус';

  @override
  String get serverProtocol => 'Протокол';

  @override
  String get serverTrustTitle => 'ДОВЕРИЕ';

  @override
  String get serverSees => 'Что видит сервер';

  @override
  String get serverCantSee => 'Чего он не видит';

  @override
  String get serverSeesTiming => 'Время доставки';

  @override
  String get serverSeesOnline => 'Статус «в сети»';

  @override
  String get serverSeesPush => 'Адрес для уведомлений';

  @override
  String get serverSeesQuota => 'Сколько места вы занимаете';

  @override
  String get serverHiddenContent => 'Текст сообщений';

  @override
  String get serverHiddenFiles => 'Файлы';

  @override
  String get serverHiddenContacts => 'Круг общения';

  @override
  String get serverTrustFooter =>
      'Так устроено само шифрование — сервер не может это отключить, даже если захочет.';

  @override
  String get devicesCurrent => 'Текущее устройство';

  @override
  String get devicesOther => 'Другие устройства';

  @override
  String get devicesOtherFooter =>
      'Ваши устройства видят одни и те же зашифрованные чаты. Отключите устройство — и уже со следующего сообщения оно не сможет читать ничего нового.';

  @override
  String get devicesOnlyOne =>
      'Это ваше единственное устройство. Чтобы пользоваться Sinhron на другом, нажмите «Подключить новое устройство» выше.';

  @override
  String devicesRemoveAll(int n) {
    return 'Отключить все другие ($n)';
  }

  @override
  String devicesLinkedCount(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: 'устройства подключено',
      many: 'устройств подключено',
      few: 'устройства подключены',
      one: 'устройство подключено',
    );
    return '$_temp0';
  }

  @override
  String get devicesHeroBody =>
      'Пользуйтесь Sinhron на всех устройствах сразу — чаты везде одинаковые и нигде не хранятся в открытом виде.';

  @override
  String get devicesLinkNew => 'Подключить новое устройство';

  @override
  String devicesModelLinked(String model, String date) {
    return '$model · подключено $date';
  }

  @override
  String devicesLastActive(String time) {
    return 'Активность: $time';
  }

  @override
  String get devicesRevoke => 'Отключить';

  @override
  String get done => 'Готово';

  @override
  String get storageVideos => 'Видео';

  @override
  String get storageVoice => 'Голосовые';

  @override
  String get storageByType => 'По типу';

  @override
  String get storageTopChats => 'Самые объёмные чаты';

  @override
  String get storageManage => 'Управление';

  @override
  String get storageMbUnit => 'МБ';

  @override
  String get phraseStatusTitle => 'Секретные слова';

  @override
  String get phraseStatusStrength => 'Надёжность';

  @override
  String get phraseStatusActions => 'Действия';

  @override
  String get phraseStatusActionsFooter =>
      'Телефон не хранит слова после сохранения — только то, что нужно для входа, — поэтому показать их ещё раз нельзя. Не уверены, что слова у вас верные? Проверьте их.';

  @override
  String get phraseStatusReverify => 'Проверить слова';

  @override
  String get phraseStatusTip =>
      'Храните 24 слова в двух местах — например, в связке ключей iCloud или менеджере паролей и на бумаге. С ними можно полностью восстановить аккаунт — любой, кто их прочтёт, сможет войти как вы на новом устройстве.';

  @override
  String get showQrTitleMy => 'Мой QR-код';

  @override
  String get showQrTitleInvite => 'Пригласить в Sinhron';

  @override
  String showQrFooterMy(String username) {
    return 'Любой, кто отсканирует этот QR-код, сможет предложить чат $username. Это не пароль и не секрет — убедиться, что это вы, можно потом по коду проверки.';
  }

  @override
  String showQrFooterInvite(String server) {
    return 'Покажите этот код другу или отправьте ссылку ниже. Кто его отсканирует, сможет начать с вами чат и подключиться к $server.';
  }

  @override
  String showQrOnServer(String server) {
    return 'на $server';
  }

  @override
  String get showQrCopyLink => 'Скопировать ссылку';

  @override
  String get showQrCopyKey => 'Скопировать адрес';

  @override
  String get showQrFooterReal =>
      'Любой, кто отсканирует этот код, сможет вам написать. В нём только ваш адрес и сервер — это не пароль, ничего секретного. Убедиться, что это правда вы, собеседник сможет в чате — «Проверить собеседника».';

  @override
  String showQrShareText(String key, String server) {
    return 'Напиши мне в Sinhron — мой адрес: $key\nСервер: $server';
  }

  @override
  String get showQrKeyCopied => 'Адрес скопирован';

  @override
  String get scanContactNotSinhron => 'Это не QR-код контакта Sinhron.';

  @override
  String scanContactOtherServer(String server) {
    return 'Этот человек на сервере $server. Чаты работают только между людьми на одном сервере.';
  }

  @override
  String get scanContactSelf => 'Это ваш собственный код.';

  @override
  String get showQrSaveImage => 'Сохранить картинку';

  @override
  String get signOutTitle => 'Выйти';

  @override
  String get signOutHeading => 'Выйти на этом устройстве';

  @override
  String get signOutReminderTitle => 'Секретные слова под рукой?';

  @override
  String get signOutReminderBody =>
      'Без ваших 24 слов на это устройство уже не вернуться. Другие устройства продолжат работать, а войти снова на этом не получится.';

  @override
  String get signOutWhatHappens => 'ЧТО ПРОИЗОЙДЁТ';

  @override
  String get signOutRowSignedOut =>
      'Это устройство выйдет из аккаунта и больше не сможет читать ваши чаты.';

  @override
  String signOutRowOtherDevices(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: 'Ещё $n вашего устройства продолжат работать — у них свои ключи.',
      many: 'Ещё $n ваших устройств продолжат работать — у них свои ключи.',
      few: 'Ещё $n ваших устройства продолжат работать — у них свои ключи.',
      one: 'Ещё $n ваше устройство продолжит работать — у него свои ключи.',
    );
    return '$_temp0';
  }

  @override
  String get signOutRowWipe => 'Чаты и ключи на этом устройстве будут стёрты.';

  @override
  String get signOutRowComeBack =>
      'Чтобы вернуться, войдите снова по 24 секретным словам.';

  @override
  String get deleteAccountTitle => 'Удалить аккаунт';

  @override
  String get profileEditServerCopied => 'Сервер скопирован';

  @override
  String get profileEditKeyCopied => 'Адрес скопирован';

  @override
  String get profileEditNoPhoneNote =>
      'Без номера телефона и логина: вам пишут по адресу или QR-коду. Имя и фото видят только ваши собеседники — они уходят к ним зашифрованными. «О себе» остаётся только на этом телефоне.';

  @override
  String get profileEditIdentityFooter =>
      'Отправьте адрес или покажите QR-код — и вам смогут написать. С важными людьми проверьте, что это точно вы друг другу пишете: «О чате» → «Проверить собеседника».';

  @override
  String get profileEditCopyKey => 'Скопировать адрес';

  @override
  String get profileEditNotReady => 'Ещё не готов';

  @override
  String get profileEditTapToCopy => 'Нажмите, чтобы скопировать';

  @override
  String get profileEditShowQr => 'Показать мой QR-код';

  @override
  String get profileEditShareHandle => 'Поделиться, чтобы мне написали';

  @override
  String get profileEditJoined => 'В Sinhron с';

  @override
  String get profileEditWhoSees => 'Кто видит ваш профиль';

  @override
  String get profileEditSignOut => 'Выйти на этом устройстве';

  @override
  String get profileEditAccountFooter =>
      'Выход затрагивает только это устройство — остальные продолжат работать. Удаление аккаунта — сразу и навсегда, отменить его нельзя.';

  @override
  String get profileEditTitle => 'Профиль';

  @override
  String get profileEditChangePhoto => 'Изменить фото';

  @override
  String get profileEditHandle => 'Сервер';

  @override
  String get profileEditStrength => 'Защита';

  @override
  String get devicesHowToLink =>
      'Или на новом устройстве нажмите «Войти по секретным словам» и введите 24 слова. Оно появится в ваших чатах, когда этот телефон будет в сети.';

  @override
  String get devicesUnnamed => 'Другое устройство';

  @override
  String get devicesFirstDevice => 'первое устройство';

  @override
  String devicesLinkedOn(String date) {
    return 'связано $date';
  }

  @override
  String get devicesRevokeTitle =>
      'Отключить это устройство? Начиная со следующего сообщения оно перестанет их получать.';

  @override
  String get devicesRevokeAction => 'Отключить устройство';

  @override
  String get devicesLoadFailed =>
      'Не удалось загрузить устройства — нет связи с сервером.';

  @override
  String get devicesRevokeFailed =>
      'Не удалось отключить устройство. Попробуйте, когда будет связь.';

  @override
  String get restoreTitle => 'Вход в свой аккаунт';

  @override
  String get restoreBody =>
      'Введите 24 секретных слова. Этот телефон станет ещё одним вашим устройством: чаты появятся здесь, пока другое ваше устройство в сети. Прежние сообщения остаются на том устройстве.';

  @override
  String get restoreAction => 'Продолжить';

  @override
  String get pairTitle => 'Привязать к аккаунту';

  @override
  String get pairBody =>
      'На устройстве, которым вы уже пользуетесь, откройте Настройки → Устройства → «Подключить новое устройство» и отсканируйте этот код.';

  @override
  String get pairWaiting => 'Ждём ваше другое устройство…';

  @override
  String get pairCopy => 'Скопировать код';

  @override
  String get pairCopied => 'Скопировано — вставьте на другом устройстве.';

  @override
  String get pairFailed =>
      'Не удалось привязать. Проверьте связь и попробуйте снова.';

  @override
  String get pairUseWords => 'Ввести 24 слова вместо этого';

  @override
  String get pairCodeUsed =>
      'Этот код забрало другое устройство. Вот новый — показывайте его только своему устройству.';

  @override
  String pairConfirm(String address) {
    return 'Войти в аккаунт с адресом $address? Сверьте: на другом телефоне в профиле должен быть тот же адрес. Если не совпадает — нажмите «Отмена».';
  }

  @override
  String get pairConfirmAction => 'Войти';

  @override
  String get restoreUseQr => 'Другое устройство рядом? Привязать по QR-коду';

  @override
  String get addDeviceBody =>
      'На новом устройстве выберите «Подключить устройство» — оно покажет QR-код. Отсканируйте его здесь.';

  @override
  String get addDeviceScan => 'Сканировать QR-код';

  @override
  String get addDevicePasteHint => '…или вставьте код';

  @override
  String get addDeviceAction => 'Добавить устройство';

  @override
  String get addDeviceNotACode => 'Это не код подключения Sinhron.';

  @override
  String addDeviceConfirm(String address) {
    return 'Дать этому устройству доступ к аккаунту? Оно будет получать все ваши новые сообщения. Новое устройство попросит сверить ваш адрес: $address.';
  }

  @override
  String get addDeviceConfirmAction => 'Дать доступ';

  @override
  String get addDeviceDone =>
      'Готово — новое устройство входит в аккаунт. В течение минуты оно появится в ваших чатах.';

  @override
  String get addDeviceFailed =>
      'Не удалось отправить. Проверьте связь и попробуйте снова.';

  @override
  String get addDeviceCodeUsed =>
      'Этот код уже использован другим устройством — если это не вы, ничего не подтверждайте.';

  @override
  String get sealedSectionTitle => 'Анонимные сообщения';

  @override
  String get sealedResetAction => 'Сбросить доступ для анонимных сообщений';

  @override
  String get sealedResetFooter =>
      'Собеседники присылают вам сообщения так, что сервер не знает, кто их отправил. Если кто-то, с кем вы больше не общаетесь, не должен так писать, сбросьте доступ — ваши текущие чаты получат новый сами.';

  @override
  String get sealedResetConfirm =>
      'Сбросить доступ? Ваши чаты получат новый сами; остальные, у кого был старый, больше не смогут писать вам анонимно.';

  @override
  String get sealedResetDone => 'Доступ сброшен';

  @override
  String get devicesNotPrimary =>
      'Это устройство подключено как дополнительное: чтобы добавить или отключить устройство, понадобятся 24 секретных слова.';

  @override
  String get phrasePromptTitle => 'Введите секретные слова';

  @override
  String get phrasePromptBody =>
      'Это устройство подключено как дополнительное. Введите 24 секретных слова, чтобы продолжить, — они нужны только для этого шага и не сохраняются.';

  @override
  String get phrasePromptAction => 'Подтвердить';

  @override
  String get proxyTitle => 'Прокси (Tor)';

  @override
  String get proxyBody =>
      'Для опытных: весь обмен с сервером пойдёт через прокси (SOCKS5) — так сервер не узнает интернет-адрес (IP) вашего телефона. Например, Tor через Orbot на 127.0.0.1:9050. Оставьте пустым — напрямую. Звонки идут без прокси.';

  @override
  String get proxySave => 'Сохранить';

  @override
  String get proxyInvalid => 'Введите адрес:порт, например 127.0.0.1:9050.';

  @override
  String devicesSeenOn(String date) {
    return 'в сети $date';
  }

  @override
  String get chatInfoTitle => 'О чате';

  @override
  String get chatInfoPersonal => 'Личный чат · зашифрован';

  @override
  String get chatInfoUnnamed => 'Имя пока не указано';

  @override
  String get chatInfoBlocked => 'Заблокирован';

  @override
  String get chatInfoBlock => 'Заблокировать';

  @override
  String chatInfoBlockConfirm(String name) {
    return 'Заблокировать: $name? Сообщения и звонки от этого человека не будут доходить до этого устройства. Человек об этом не узнает.';
  }

  @override
  String get chatInfoMemberProfile => 'Профиль';

  @override
  String get chatInfoVerify => 'Проверить собеседника';

  @override
  String chatInfoMemberSafety(String name) {
    return 'Проверить: $name';
  }

  @override
  String get incomingCalls => 'Входящие звонки';

  @override
  String get incomingCallsFooter =>
      'Выключено: входящие звонки сбрасываются без звонка. Звонить самим можно.';

  @override
  String get blockedUnnamed => 'Без имени';

  @override
  String get reorderPinned => 'Изменить порядок закреплённых';

  @override
  String get reorderPinnedTitle => 'Закреплённые чаты';

  @override
  String get reorderHint =>
      'Удерживайте строку и перетащите, чтобы изменить порядок.';

  @override
  String get chatFolders => 'Папки с чатами';

  @override
  String get chatFoldersHint =>
      'Папки — это вкладки над списком чатов. Удерживайте папку и перетащите, чтобы поменять порядок; выключите — чтобы скрыть вкладку.';

  @override
  String get myFolders => 'Мои папки';

  @override
  String get createFolder => 'Создать папку';

  @override
  String get suggestedFolders => 'Готовые папки';

  @override
  String get addFolder => 'Добавить';

  @override
  String get folderMuted => 'Без звука';

  @override
  String get folderMutedHint => 'Чаты с выключенным звуком';

  @override
  String get folderNotMuted => 'Со звуком';

  @override
  String get folderNotMutedHint => 'Чаты с уведомлениями';

  @override
  String get folderArchived => 'Архив';

  @override
  String get folderArchivedHint => 'Чаты, убранные в архив';

  @override
  String folderChatCount(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: '$n чата',
      many: '$n чатов',
      few: '$n чата',
      one: '$n чат',
      zero: 'Нет чатов',
    );
    return '$_temp0';
  }

  @override
  String get folderBuiltIn => 'Стандартная';

  @override
  String get hideFolder => 'Скрыть папку';

  @override
  String showFolderTab(String name) {
    return 'Показывать вкладку «$name»';
  }

  @override
  String get editFolders => 'Настроить папки';

  @override
  String get folderChatTypes => 'Типы чатов';

  @override
  String get folderWhichChats => 'Какие чаты';

  @override
  String get onlyUnread => 'Только непрочитанные';

  @override
  String get ruleShow => 'Показывать';

  @override
  String get ruleHide => 'Скрывать';

  @override
  String get ruleOnly => 'Только они';

  @override
  String get folderRulesFooter =>
      'Чаты без звука и из архива: показывать, скрывать или показывать только их.';

  @override
  String get folderReorderHint => 'Удерживайте вкладку и перетащите её.';

  @override
  String get verifyScan => 'Сканировать код собеседника';

  @override
  String verifyScanMatch(String name) {
    return 'Коды совпали — $name: проверено.';
  }

  @override
  String get verifyScanMismatch =>
      'Коды не совпадают. Не отмечайте проверку — сравните цифры при личной встрече.';

  @override
  String get verifyScanNotCode => 'Этот QR — не код проверки Sinhron.';

  @override
  String get recordVideo => 'Снять видео';

  @override
  String get videoFromLibrary => 'Выбрать из галереи';

  @override
  String get requestTitle => 'Запрос на переписку';

  @override
  String get requestBody =>
      'Пока вы не примете запрос, собеседник не увидит, что вы прочитали сообщения, не узнает вашего имени, а звонки из этого чата не будут звонить.';

  @override
  String get requestAccept => 'Принять';

  @override
  String get screenRecordingByMe => 'Вы записываете экран';

  @override
  String screenRecordingByPeer(String name) {
    return '$name: запись экрана';
  }

  @override
  String get screenshotByMe => 'Вы сделали снимок экрана';

  @override
  String screenshotByPeer(String name) {
    return '$name: снимок экрана';
  }

  @override
  String get requestBlockFailed =>
      'Не удалось заблокировать — попробуйте, когда будет связь.';

  @override
  String get errVideoTooLarge =>
      'Видео слишком большое для отправки (не больше 95 МБ) даже после сжатия.';

  @override
  String get profileEditChoosePhoto => 'Выбрать фото';

  @override
  String get profileEditRemovePhoto => 'Удалить фото';

  @override
  String get groupYouWereRemoved => 'Вас удалили из группы.';

  @override
  String groupMemberLeft(String name) {
    return '$name вышел(а) из группы.';
  }

  @override
  String groupYouRemoved(String names) {
    return 'Вы удалили: $names.';
  }

  @override
  String groupSomeoneAdded(String by, String names) {
    return '$by добавил(а): $names.';
  }

  @override
  String groupSomeoneRemoved(String by, String names) {
    return '$by удалил(а): $names.';
  }

  @override
  String groupYouRenamed(String name) {
    return 'Вы переименовали группу в «$name».';
  }

  @override
  String groupSomeoneRenamed(String by, String name) {
    return '$by переименовал(а) группу в «$name».';
  }

  @override
  String get groupLeave => 'Выйти из группы';

  @override
  String groupLeaveConfirm(String name) {
    return 'Выйти из «$name»? Сообщения группы больше не будут приходить, а чат удалится с этого устройства.';
  }

  @override
  String get groupRename => 'Переименовать группу';

  @override
  String get groupRemoveMember => 'Удалить из группы';

  @override
  String groupRemoveConfirm(String name) {
    return 'Удалить $name из группы? Новые сообщения он(а) прочитать не сможет.';
  }

  @override
  String get groupAdmin => 'админ';

  @override
  String get groupNotMember => 'Вы больше не участник этой группы.';

  @override
  String get groupActionFailed =>
      'Не получилось — проверьте соединение и попробуйте ещё раз.';

  @override
  String get chatMissedCall => 'Пропущенный звонок';

  @override
  String get chatMissedVideoCall => 'Пропущенный видеозвонок';

  @override
  String get callNoAnswer => 'Нет ответа';

  @override
  String get callCouldntConnect => 'Не удалось соединить звонок';

  @override
  String get callNotEncrypted =>
      'Звонок прерван: сервер пытался отключить шифрование';

  @override
  String get callBusy => 'Занято';

  @override
  String get callDeclinedByPeer => 'Звонок отклонён';

  @override
  String get callMissedShort => 'Пропущенный звонок';

  @override
  String get callsBusy => 'Занято';

  @override
  String get callsCancelled => 'Отменён';

  @override
  String get callsMissedOne => 'Пропущенный';

  @override
  String get callsCallBack => 'Перезвонить';

  @override
  String get callsOpenChat => 'Открыть чат';

  @override
  String get storageOther => 'Другое';

  @override
  String get storageDatabase => 'Сообщения';

  @override
  String get storageUsedHere => 'занимает Sinhron на этом телефоне';

  @override
  String get storageTopChatsRealFooter =>
      'Копии фото, видео, голосовых и файлов на этом телефоне — по чатам.';

  @override
  String get storageClearCopies => 'Удалить копии медиа';

  @override
  String get storageClearCopiesConfirm =>
      'Удалить копии фото, видео и файлов на этом телефоне? Сообщения останутся. Файл снова загрузится с сервера, когда вы его откроете, — но тот, что сервер уже удалил (через 90 дней после последнего открытия кем-либо), не вернётся.';

  @override
  String storageCopiesCleared(String size) {
    return 'Освобождено $size';
  }

  @override
  String get storageClearCopiesFooter =>
      'Копии медиа открываются без интернета и остаются, когда сервер удаляет старые файлы. Сами сообщения и их текст здесь не удаляются.';

  @override
  String get deleteAccountWord => 'УДАЛИТЬ';

  @override
  String get deleteAccountCannotUndo => 'Это нельзя отменить';

  @override
  String deleteAccountServer(String server) {
    return 'Аккаунт сразу удаляется с $server: ваш адрес, устройства и сообщения, которые ждут доставки.';
  }

  @override
  String get deleteAccountGroups =>
      'Группы узнают, что вы вышли; написать вам больше нельзя.';

  @override
  String get deleteAccountThisPhone =>
      'Чаты, медиа и ключи стираются с этого телефона.';

  @override
  String deleteAccountOtherDevices(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: 'Ваши $n других устройств перестанут работать.',
      few: 'Ваши $n других устройства перестанут работать.',
      one: 'Ваше другое устройство перестанет работать.',
    );
    return '$_temp0';
  }

  @override
  String get deleteAccountSentStays =>
      'Сообщения и файлы, которые вы уже отправили, останутся у получателей.';

  @override
  String get deleteAccountPhrase =>
      'С вашими 24 словами можно зарегистрироваться снова, но эти чаты и группы не вернутся. Резервная копия чатов в iCloud / Google Диске тоже удаляется, если телефон может до неё добраться.';

  @override
  String deleteAccountTypeWord(String word) {
    return 'Введите $word, чтобы подтвердить';
  }

  @override
  String get deleteAccountFailed =>
      'Не получилось удалить аккаунт — проверьте соединение и попробуйте ещё раз. Ничего не стёрто.';

  @override
  String get reportAction => 'Пожаловаться';

  @override
  String reportTitle(String name) {
    return 'Пожаловаться на $name?';
  }

  @override
  String reportBody(String server) {
    return 'Жалоба уйдёт оператору сервера $server. Он не может читать ваши чаты — только то, что вы сами отправите.';
  }

  @override
  String get reportWithMessage => 'Пожаловаться и отправить это сообщение';

  @override
  String get reportWithoutMessage => 'Пожаловаться без сообщения';

  @override
  String get reportAndBlock => 'Пожаловаться и заблокировать';

  @override
  String get reportReasonTitle => 'Что не так?';

  @override
  String get reportReasonSpam => 'Спам';

  @override
  String get reportReasonAbuse => 'Оскорбления или угрозы';

  @override
  String get reportReasonIllegal => 'Незаконный контент';

  @override
  String get reportReasonOther => 'Другое';

  @override
  String get reportSent => 'Жалоба отправлена. Спасибо.';

  @override
  String get reportFailed =>
      'Не получилось отправить жалобу — проверьте соединение и попробуйте ещё раз.';

  @override
  String get legalSection => 'Помощь и правила';

  @override
  String get legalTermsRow => 'Условия использования';

  @override
  String get legalPrivacyRow => 'Политика конфиденциальности';

  @override
  String get reportProblemTitle => 'Сообщить о проблеме';

  @override
  String get reportProblemHint =>
      'Отправить журнал приложения тому, кто помогает';

  @override
  String get reportProblemNoteHint =>
      'Что случилось? Например: «звонок соединился, но без звука»';

  @override
  String get reportProblemWhat =>
      'В отчёт войдёт журнал приложения за последний час — подключение, уведомления, звонки, — версия приложения и модель телефона. Без текста сообщений, имён и ключей.';

  @override
  String get reportProblemPreview => 'Посмотреть отчёт';

  @override
  String get reportProblemHidePreview => 'Скрыть отчёт';

  @override
  String get reportProblemSend => 'Отправить';

  @override
  String get reportProblemCopy => 'Скопировать';

  @override
  String get reportProblemCopied => 'Отчёт скопирован';

  @override
  String get pasteMarkdownDone => 'Разметка стала форматированием';

  @override
  String get pasteMarkdownRevert => 'Вернуть как было';

  @override
  String get reportProblemFailed =>
      'Не получилось собрать отчёт. Попробуйте ещё раз.';

  @override
  String get reportProblemSendHint =>
      '«Отправить» откроет меню «Поделиться»: выберите Sinhron и чат с тем, кто вам помогает, — или Telegram, почту, если Sinhron не подключается.';

  @override
  String get backupTitle => 'Резервная копия';

  @override
  String get backupHint => 'Переписка и медиа — в вашем облаке';

  @override
  String get backupWhere => 'Где хранится';

  @override
  String get backupWhereDrive => 'Google Диск';

  @override
  String get backupNotConnected => 'Не подключено';

  @override
  String get backupSignInGoogle => 'Войти через Google';

  @override
  String get backupSignOutGoogle => 'Выйти из Google';

  @override
  String get backupIcloudOff =>
      'Включите iCloud Drive в настройках iPhone (ваше имя → iCloud → iCloud Drive)';

  @override
  String get backupDaily => 'Копия каждый день';

  @override
  String get backupLast => 'Последняя копия';

  @override
  String get backupNever => 'Ещё не было';

  @override
  String get backupNow => 'Создать копию сейчас';

  @override
  String get backupRunning => 'Создаю копию…';

  @override
  String backupRunningMedia(int done, int total) {
    return 'Медиа: $done из $total';
  }

  @override
  String get backupFailed =>
      'Не получилось. Проверьте интернет и попробуйте ещё раз.';

  @override
  String get backupDone => 'Копия сохранена';

  @override
  String get backupRestoreSection => 'Восстановление';

  @override
  String get backupRestore => 'Восстановить из копии';

  @override
  String backupRestoreNone(String where) {
    return '$where: копия не найдена';
  }

  @override
  String get backupRestoreAskTitle => 'Восстановить переписку?';

  @override
  String backupRestoreAskBody(String date, int messages, int chats, int media) {
    return 'Копия от $date: сообщений — $messages, чатов — $chats, медиафайлов — $media.';
  }

  @override
  String backupRestoreOlder(String newer) {
    return 'Была копия новее ($newer) — её в облаке больше нет, эта старше. Сообщений после неё не будет.';
  }

  @override
  String get backupRestoreGo => 'Восстановить';

  @override
  String backupRestoring(int done, int total) {
    return 'Восстанавливаю… $done из $total';
  }

  @override
  String get backupRestored => 'Переписка восстановлена';

  @override
  String backupRestoredAdded(int n) {
    return 'Переписка восстановлена: добавлено сообщений — $n';
  }

  @override
  String get backupRestoredNothingNew =>
      'В копии нет ничего нового — всё уже здесь';

  @override
  String get backupUploadPending =>
      'Ещё загружается в iCloud — другие устройства увидят её, когда iPhone отправит (обычно по Wi‑Fi)';

  @override
  String get backupFooter =>
      'Копия зашифрована вашими 24 секретными словами: ни Apple, ни Google её не прочитают, а без слов её не восстановить.';

  @override
  String get backupUnlockRow => 'Включить копию на этом устройстве';

  @override
  String get backupUnlockRowHint => 'Нужны 24 слова — один раз';

  @override
  String get backupUnlockTitle => 'Включить копию здесь';

  @override
  String get backupUnlockBody =>
      'Это устройство подключено до того, как появились копии. Введите 24 слова один раз — сами слова не сохраняются.';

  @override
  String get backupUnlockGo => 'Включить';

  @override
  String get backupUnlockOtherWords => 'Это слова другого аккаунта';

  @override
  String get backupOfferDriveTitle => 'Найти копию переписки в Google Диске?';

  @override
  String get backupOfferDriveBody =>
      'Если старый телефон делал копию, переписка вернётся. Нужно войти в тот же аккаунт Google.';

  @override
  String get backupOfferDriveGo => 'Войти через Google';

  @override
  String get backupRestoreStarted =>
      'Восстанавливаю переписку — можно пользоваться приложением';

  @override
  String get oldDevicesTitle => 'Ваши другие устройства';

  @override
  String get oldDevicesBody =>
      'Если старый телефон потерян, продан или сломан — отключите его: он больше не получит ни сообщений, ни звонков и уйдёт из ваших чатов. Нужно только сейчас, пока введены 24 слова.';

  @override
  String get oldDevicesDisconnect => 'Отключить';

  @override
  String get oldDevicesDisconnected => 'Отключено';

  @override
  String get legalSupportRow => 'Помощь и поддержка';

  @override
  String get legalTermsIntro =>
      'Пользуясь Sinhron, вы принимаете эти правила. Они действуют для всех на этом сервере.';

  @override
  String get legalTermsBody =>
      'Никакой терпимости к недопустимому контенту и оскорбителям. Не отправляйте спам, угрозы, травлю, ненависть, сексуальный контент с участием несовершеннолетних и ничего незаконного там, где живёте вы или получатель.\n\nЖалоба и блокировка. В любом чате можно пожаловаться на человека или сообщение. Жалоба уходит оператору вашего сервера: он её рассматривает и может удалить аккаунт — обычно в течение 24 часов. Блокировка сразу скрывает человека от вас.\n\nСообщения зашифрованы сквозным шифрованием: оператор не может их прочитать. В жалобе — только то, что вы сами решили отправить.\n\nОператор может удалить аккаунт, нарушающий правила. Свой аккаунт вы можете удалить в любой момент: Профиль → Удалить аккаунт.';

  @override
  String get legalPrivacyBody =>
      'Сообщения, звонки, фото и файлы шифруются на ваших устройствах; сервер только передаёт их в зашифрованном виде и прочитать не может.\n\nСервер знает: ваш адрес в Sinhron, ваши устройства, в каких вы группах и когда отправляются сообщения — это нужно, чтобы их доставить. Он не знает вашего имени, фото, контактов и содержимого сообщений.\n\nНичего не продаётся и не передаётся рекламодателям. Нет рекламы и аналитики.\n\nАккаунт можно удалить в любой момент (Профиль → Удалить аккаунт): сервер удалит ваш адрес, устройства и сообщения, ждущие доставки.';

  @override
  String get legalSupportBody =>
      'Вопросы, проблемы, жалоба на кого-то — пишите оператору вашего сервера.';

  @override
  String legalSupportOperator(String server) {
    return 'Сервер: $server';
  }

  @override
  String get legalSupportReportHint =>
      'Чтобы пожаловаться на человека или сообщение, удерживайте сообщение или откройте информацию о чате и выберите «Пожаловаться».';

  @override
  String get welcomeAgreeTerms =>
      'Продолжая, вы принимаете Условия использования';

  @override
  String get pushToggle => 'Уведомления о сообщениях';

  @override
  String get pushFooterOn =>
      'Когда Sinhron закрыт, телефон показывает «Новое сообщение» — без текста и имени: сервер не может читать сообщения. Предпросмотр появится в следующих версиях.';

  @override
  String get pushDenied =>
      'Уведомления выключены в Настройки iOS → Sinhron → Уведомления.';

  @override
  String get pushNoDistributor =>
      'На телефоне нет приложения для уведомлений. Установите ntfy (Google Play или F-Droid) — через него Sinhron будит телефон. Какой сервер вписать в ntfy, Sinhron покажет здесь, когда будет на связи.';

  @override
  String get keepConnected => 'Постоянное соединение';

  @override
  String get keepConnectedFooter =>
      'Нужно, только если звонки и сообщения не приходят, пока Sinhron закрыт. Обычно включается и выключается само: без нужды оно только тратит батарею.';

  @override
  String get callsReachYes => 'Звонки дойдут: да';

  @override
  String get callsReachNo => 'Звонки дойдут: нет — что сделать';

  @override
  String get callsReachViaGoogle =>
      'Даже если Sinhron закрыт или смахнут. Google видит только, что для Sinhron что-то пришло, — не что и не от кого.';

  @override
  String get callsReachViaNtfy => 'Даже если Sinhron закрыт.';

  @override
  String get callsReachViaAlways =>
      'Через «Постоянное соединение»: Sinhron остаётся на связи в фоне.';

  @override
  String get callsReachNone =>
      'Пока Sinhron закрыт, телефон ничего не разбудит.';

  @override
  String get reachFixNotifications => 'Разрешить уведомления';

  @override
  String get reachFixCalls => 'Включить входящие звонки';

  @override
  String get reachFixAlways => 'Включить «Постоянное соединение»';

  @override
  String get reachFixBackground => 'Разрешить работу в фоне';

  @override
  String get reachSamsung => 'Samsung: «Никогда не спящие приложения»';

  @override
  String get reachSamsungSub =>
      'Добавьте туда Sinhron — телефон не будет его усыплять';

  @override
  String get ntfyTitle => 'Уведомления через ntfy';

  @override
  String ntfyInstallSteps(String url) {
    return 'Чтобы Sinhron будил телефон, нужно бесплатное приложение ntfy.\n1. Установите ntfy из Google Play или F-Droid.\n2. В ntfy откройте меню ⋮ → Настройки → Сервер по умолчанию и впишите $url\n3. Вернитесь сюда и нажмите «Подключить ntfy».';
  }

  @override
  String ntfySetServerSteps(String url) {
    return 'ntfy установлен, но ещё не подключён.\n1. В ntfy откройте меню ⋮ → Настройки → Сервер по умолчанию и впишите $url\n2. Вернитесь сюда и нажмите «Подключить ntfy».';
  }

  @override
  String ntfyOtherServerSteps(String other, String url) {
    return 'ntfy настроен на другой сервер ($other) — через него уведомления Sinhron не приходят.\n1. В ntfy откройте меню ⋮ → Настройки → Сервер по умолчанию и впишите $url\n2. Вернитесь сюда и нажмите «Подключить ntfy».';
  }

  @override
  String get ntfyServerHasNone =>
      'Ваш сервер Sinhron не отправляет уведомления на Android. Включите ниже «Постоянное соединение» — тогда Sinhron будет на связи сам.';

  @override
  String get ntfyCopyAddress => 'Скопировать адрес сервера';

  @override
  String get ntfyAddressCopied => 'Адрес скопирован';

  @override
  String get ntfyInstall => 'Установить ntfy';

  @override
  String get ntfyOpen => 'Открыть ntfy';

  @override
  String get ntfyConnect => 'Подключить ntfy';

  @override
  String get ntfyConnecting => 'Подключаем ntfy…';

  @override
  String get asInSystem => 'Как в настройках системы';

  @override
  String get setPasscodeFirstAndroid =>
      'Сначала задайте блокировку экрана на телефоне — блокировка Sinhron использует её.';

  @override
  String get appLockFooterAndroid =>
      'Sinhron будет спрашивать отпечаток, лицо или блокировку экрана при открытии. Чаты зашифрованы в любом случае.';

  @override
  String get unlockPhraseNoteAndroid =>
      'Слова не покидают телефон и не сохраняются — телефон запомнит только сделанный из них ключ, в защищённом хранилище Android.';

  @override
  String get navErrNotConnected =>
      'Нет соединения с сервером — переподключаемся. Попробуйте ещё раз через несколько секунд.';

  @override
  String get callSwitchingPath =>
      'Связь рвётся — переключаемся на запасной путь…';

  @override
  String get callsReserveSection => 'Звонки';

  @override
  String get callsReserve => 'Звонки через запасной путь';

  @override
  String get callsReserveFooter =>
      'Звук и видео пойдут через ваш сервер так же, как открывается обычный сайт, — для сетей, где звонок соединяется и сразу обрывается. Шифрование остаётся. Sinhron и сам переключается, если звонок рвётся.';

  @override
  String inviteShareText(String link) {
    return 'Присоединяйся ко мне в Sinhron — мессенджере с шифрованием. Установи приложение и нажми ссылку, я сразу появлюсь у тебя в контактах: $link';
  }

  @override
  String get inviteForged =>
      'Ссылка-приглашение изменена или подделана — не открываем. Попросите прислать её ещё раз.';

  @override
  String get inviteDamaged =>
      'Ссылка-приглашение повреждена. Попросите прислать её ещё раз.';

  @override
  String get inviteExpired => 'Ссылка устарела — попросите новую';

  @override
  String get inviteOffline =>
      'Не удалось открыть приглашение — нет связи с его сервером. Нажмите ссылку ещё раз чуть позже.';

  @override
  String inviteKeyRow(String fingerprint) {
    return 'Адрес $fingerprint';
  }

  @override
  String get inviteYourServer => 'Ваш сервер';

  @override
  String inviteAddContact(String name) {
    return 'Добавить $name в контакты';
  }

  @override
  String get inviteServerChecking => 'Проверяем сервер…';

  @override
  String get inviteServerOk => 'Сервер на связи';

  @override
  String get inviteServerUnreachable =>
      'Сервер сейчас не отвечает — можно продолжить';

  @override
  String get inviteNotSinhron => 'По этому адресу не сервер Sinhron';

  @override
  String get inviteNotSaved =>
      'Не удалось сохранить сервер на телефоне — попробуйте ещё раз';

  @override
  String get notificationPreviewTitle => 'Что показывать в уведомлениях';

  @override
  String get notificationPreviewNameAndText => 'Имя и текст';

  @override
  String get notificationPreviewNameOnly => 'Только имя';

  @override
  String get notificationPreviewNothing => 'Ничего — просто «Новое сообщение»';

  @override
  String get notificationPreviewFooter =>
      'Для баннеров в приложении, уведомлений Android и имени в истории звонков iPhone. На iPhone, когда Sinhron закрыт, уведомление всегда просто «Новое сообщение»: ваш сервер не может прочитать, кто написал и что.';

  @override
  String get callDiagnostics => 'Диагностика звонка';

  @override
  String get callShareScreen => 'Показать экран';

  @override
  String get callSharingScreen => 'Вы показываете экран';

  @override
  String get callStopSharing => 'Остановить';

  @override
  String callScreenOf(String name) {
    return '$name показывает экран';
  }

  @override
  String get callScreenBackToCall => 'К звонку';

  @override
  String callScreenWatch(String name) {
    return 'Смотреть экран: $name';
  }

  @override
  String get callScreenRotate => 'Повернуть';

  @override
  String get callScreenShareFailed => 'Не удалось показать экран';

  @override
  String get callAudioOutput => 'Куда выводить звук';

  @override
  String get callAudioPhone => 'Телефон';

  @override
  String get callAudioHeadphones => 'Наушники';

  @override
  String get callAudioCar => 'Машина';

  @override
  String get callAudioOther => 'Другое устройство';

  @override
  String get callKeepsDropping =>
      'Связь со звонком обрывается. Если включён VPN — попробуйте выключить его';

  @override
  String get searchCalls => 'Поиск звонков';

  @override
  String get callsNewCallTitle => 'Кому позвонить?';

  @override
  String get storageKeepCopies => 'Хранить копии медиа';

  @override
  String get storageKeepForever => 'Всегда';

  @override
  String get storageKeepMonth => 'Месяц';

  @override
  String get storageKeepWeek => 'Неделю';

  @override
  String get storageKeepFooter =>
      'Копию, которую столько не открывали, телефон удалит; сообщение останется, а файл снова загрузится с сервера, пока он там есть (90 дней с последней загрузки).';

  @override
  String get emojiRecent => 'Недавние';

  @override
  String get emojiSmileys => 'Смайлики и эмоции';

  @override
  String get emojiPeople => 'Люди и тело';

  @override
  String get emojiAnimals => 'Животные и природа';

  @override
  String get emojiFood => 'Еда и напитки';

  @override
  String get emojiActivities => 'Занятия';

  @override
  String get emojiTravel => 'Путешествия и места';

  @override
  String get emojiObjects => 'Предметы';

  @override
  String get emojiSymbols => 'Символы';

  @override
  String get emojiFlags => 'Флаги';

  @override
  String get emojiDelete => 'Стереть';

  @override
  String get emojiKeyboard => 'Клавиатура';

  @override
  String get emojiTab => 'Эмодзи';

  @override
  String get stickersTab => 'Стикеры';

  @override
  String get emojiSearch => 'Поиск эмодзи';

  @override
  String get emojiNothingFound => 'Ничего не нашлось';

  @override
  String get emojiSkinTone => 'Оттенок кожи';

  @override
  String get stickersAdd => 'Добавить стикеры';

  @override
  String get stickersFromFiles => 'Из файлов — .tgs, .webp, .webm, .zip';

  @override
  String get stickersFromCode => 'Вставить ссылку или код набора';

  @override
  String get stickersNoCode =>
      'Скопируйте ссылку t.me/addstickers/… или код набора и нажмите снова';

  @override
  String get stickersImporting => 'Добавляю стикеры…';

  @override
  String get stickersImportFailed =>
      'Не удалось добавить стикеры: в файлах нет подходящих';

  @override
  String stickersImported(String title) {
    return 'Набор «$title» добавлен';
  }

  @override
  String get myStickersTitle => 'Мои стикеры';

  @override
  String get stickersAll => 'Все';

  @override
  String get stickersFound => 'Нашлось';

  @override
  String stickersNone(String emoji) {
    return 'Стикеров с $emoji нет';
  }

  @override
  String stickerPackAdd(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count стикера',
      many: '$count стикеров',
      few: '$count стикера',
      one: '$count стикер',
    );
    return 'Добавить $_temp0';
  }

  @override
  String get stickerPackAdded => 'Набор добавлен';

  @override
  String get stickerPackAlready => 'Этот набор уже у вас';

  @override
  String get stickerPackShare => 'Поделиться набором';

  @override
  String get stickerPackCopyCode => 'Скопировать код набора';

  @override
  String get stickerPackCodeCopied => 'Код набора скопирован';

  @override
  String stickerPackShareText(String code) {
    return 'Мои стикеры для Синхрона — в панели стикеров нажмите + и вставьте этот код: $code';
  }

  @override
  String get stickerPackDelete => 'Удалить набор';

  @override
  String get stickerPackBuiltin => 'Встроенный набор';

  @override
  String stickerPackCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count стикера',
      many: '$count стикеров',
      few: '$count стикера',
      one: '$count стикер',
    );
    return '$_temp0';
  }

  @override
  String get stickerPackUnavailable =>
      'Не удалось открыть набор — проверьте связь';

  @override
  String get stickerPackNotShared => 'Стикер пришёл без своего набора';

  @override
  String get stickerPackOptions => 'Действия с набором';

  @override
  String get tgPackFrom => 'Из Telegram';

  @override
  String get tgPackLoading => 'Открываю набор из Telegram…';

  @override
  String tgPackDownloading(int done, int total) {
    return 'Загружаю стикеры: $done из $total';
  }

  @override
  String get tgPackNotFound => 'Набор не найден — проверьте ссылку';

  @override
  String get tgPackNotConfigured =>
      'Сервер не настроен для наборов из Telegram — попросите того, кто его держит';

  @override
  String get tgPackServerOld =>
      'Сервер пока не умеет загружать наборы из Telegram — его нужно обновить';

  @override
  String get tgPackUnreachable =>
      'Сервер сейчас не достаёт до Telegram — попробуйте позже';

  @override
  String get tgPackRateLimited =>
      'Слишком много наборов подряд — попробуйте через несколько минут';

  @override
  String get tgPackFailed => 'Не удалось загрузить набор — проверьте связь';

  @override
  String get tgPackAddToSinhron => 'Добавить стикеры в Sinhron';

  @override
  String tgPackAddedPartly(String title, int count) {
    return 'Набор «$title» добавлен; не загрузилось: $count';
  }

  @override
  String get kindSticker => 'Стикер';

  @override
  String get whatSticker => 'стикер';

  @override
  String a11ySticker(String emoji) {
    return 'Стикер $emoji';
  }

  @override
  String get accentBlue => 'Синий';

  @override
  String get accentViolet => 'Фиолетовый';

  @override
  String get accentGreen => 'Зелёный';

  @override
  String get accentOrange => 'Оранжевый';

  @override
  String get accentPink => 'Розовый';

  @override
  String get accentGraphite => 'Графит';

  @override
  String get tapToReveal => 'Нажмите, чтобы показать';

  @override
  String get textSelectAll => 'Выбрать всё';

  @override
  String get textPaste => 'Вставить';

  @override
  String get textCut => 'Вырезать';

  @override
  String get formatMenu => 'Формат';

  @override
  String get formatBold => 'Жирный';

  @override
  String get formatItalic => 'Курсив';

  @override
  String get formatUnderline => 'Подчёркнутый';

  @override
  String get formatStrike => 'Зачёркнутый';

  @override
  String get formatMono => 'Моноширинный';

  @override
  String get formatSpoiler => 'Спойлер';

  @override
  String get formatLink => 'Ссылка';

  @override
  String get formatQuote => 'Цитата';

  @override
  String get formatClear => 'Очистить формат';

  @override
  String get linkSheetTitle => 'Ссылка';

  @override
  String get linkSheetHint => 'Адрес, например https://…';

  @override
  String get linkSheetBad => 'Это не похоже на адрес';

  @override
  String get linkSheetDone => 'Готово';

  @override
  String get linkSheetRemove => 'Убрать ссылку';

  @override
  String get linkHiddenWarning =>
      'Текст ссылки и её адрес разные — проверьте, куда она ведёт';

  @override
  String get codeCopy => 'Копировать';

  @override
  String get codeCopied => 'Код скопирован';

  @override
  String get a11ySpoiler => 'Скрытый текст, коснитесь дважды, чтобы показать';

  @override
  String get a11yQuote => 'Цитата';

  @override
  String get a11yCodeBlock => 'Код';

  @override
  String get callBarIncoming => 'Входящий звонок';

  @override
  String get callBarEnded => 'Звонок завершён';

  @override
  String get profileSaveFailed =>
      'Не удалось сохранить профиль — попробуйте ещё раз';

  @override
  String get signOutFailed => 'Не удалось выйти — попробуйте ещё раз';

  @override
  String get startingChat => 'Создаём зашифрованный чат…';

  @override
  String get restoreFailed =>
      'Не удалось войти — проверьте связь и попробуйте ещё раз. Слова остались в поле.';

  @override
  String get requestAcceptFailed =>
      'Не удалось принять запрос — проверьте связь и попробуйте ещё раз';

  @override
  String get sendQueuedOffline =>
      'Нет связи — сообщение уйдёт само, как только она появится';

  @override
  String safetyNumberA11y(String groups) {
    return 'Код проверки: $groups';
  }

  @override
  String callMicMode(String mode) {
    return 'Микрофон: $mode';
  }

  @override
  String get callMicStandard => 'стандарт';

  @override
  String get callMicVoiceIsolation => 'изоляция голоса';

  @override
  String get callMicWideSpectrum => 'широкий спектр';

  @override
  String get callMinimize => 'Свернуть — звонок продолжится';

  @override
  String get callPeerMicOff => 'Микрофон выключен';

  @override
  String get callConnecting => 'Соединяем…';

  @override
  String get callBarReturn => 'вернуться';

  @override
  String get callBarAnswer => 'ответить';

  @override
  String get myProfileTitle => 'Мой профиль';

  @override
  String get myProfileShare => 'Поделиться, чтобы мне написали';

  @override
  String get myProfileQrHint =>
      'Покажите этот код — отсканировав его, вам смогут написать. Это не пароль: ничего секретного в нём нет.';

  @override
  String get myProfileAddress => 'Ваш адрес в Sinhron';

  @override
  String get myProfileNotReady =>
      'Адрес появится, когда телефон подключится к серверу.';

  @override
  String get myProfileNoBio => 'Пара слов о себе — нажмите «Изменить»';

  @override
  String get settingsProfileHint => 'Профиль и QR-код, чтобы вам написали';

  @override
  String get settingsNotificationsHint =>
      'Звук, вибрация и что видно в уведомлении';

  @override
  String get settingsPrivacyHint => 'Кто видит, что вы в сети и что прочитали';

  @override
  String get settingsAppLockHint => 'Спрашивать Face ID или код при открытии';

  @override
  String get settingsAppLockHintAndroid =>
      'Спрашивать отпечаток или код при открытии';

  @override
  String get settingsAppearanceHint => 'Тема, цвет и обои';

  @override
  String get settingsChatsSection => 'Чаты и папки';

  @override
  String get settingsNewFolderHint => 'Например, «Работа» или «Семья»';

  @override
  String get settingsArchiveHint => 'Чаты, которые вы убрали из списка';

  @override
  String get settingsStorageHint => 'Сколько места занимают фото и видео';

  @override
  String get settingsAccountSection => 'Аккаунт и устройства';

  @override
  String get settingsDevicesHint => 'Телефоны и компьютеры с вашим аккаунтом';

  @override
  String get settingsWordsHint => 'Вернут аккаунт на новом телефоне';

  @override
  String get settingsAdvanced => 'Для опытных';

  @override
  String get settingsProxyHint =>
      'Скрыть IP телефона от сервера; запасной путь для звонков';

  @override
  String get settingsHelpHint => 'Вопросы, проблемы, жалобы';

  @override
  String get transferOutTitle => 'Переношу всё на новое устройство';

  @override
  String get transferInTitle => 'Переношу всё с другого устройства';

  @override
  String get transferStageBuild => 'Собираю переписку, контакты и настройки…';

  @override
  String transferStageUpload(int done, int total) {
    return 'Отправляю: $done из $total';
  }

  @override
  String get transferStageOffer => 'Сообщаю новому устройству…';

  @override
  String transferStageMedia(int done, int total) {
    return 'Фото и файлы: $done из $total';
  }

  @override
  String get transferStageManifest => 'Готовлюсь…';

  @override
  String transferStageParts(int done, int total) {
    return 'Получаю переписку: $done из $total';
  }

  @override
  String get transferStagePacks => 'Загружаю стикеры…';

  @override
  String transferDone(int messages) {
    return 'Готово — перенесено сообщений: $messages';
  }

  @override
  String transferDoneMediaLater(int messages) {
    return 'Сообщения на месте ($messages). Фото и файлы открываются по мере того, как другое устройство их выкладывает';
  }

  @override
  String transferDoneMissing(int messages, int missing) {
    return 'Готово — сообщений: $messages. Фото и файлов, которых уже нигде нет: $missing';
  }

  @override
  String get transferFailed =>
      'Перенос не закончился. На другом устройстве: «Устройства» → это устройство → «Отправить всё»';

  @override
  String get transferWaiting => 'Нет связи — продолжу, когда она появится';

  @override
  String get transferHide => 'Скрыть';

  @override
  String get transferStop => 'Остановить';

  @override
  String transferStrip(int percent) {
    return 'Переношу переписку… $percent%';
  }

  @override
  String get devicesSendAll => 'Отправить всё на это устройство';

  @override
  String get devicesSendAllFailed =>
      'Не удалось начать перенос. Проверьте связь и попробуйте ещё раз.';

  @override
  String get devicesSyncNote =>
      'Устройства живут одной жизнью: чаты со всей историей, контакты, заблокированные, стикеры, папки и настройки приватности. Вид, звуки и настройки связи — у каждого устройства свои.';

  @override
  String get serverChatTitle => 'Сервер';

  @override
  String get serverChatSubtitle => 'Служебные уведомления · для администратора';

  @override
  String get serverChatEmpty => 'Пока тихо — уведомлений нет.';

  @override
  String get serverChatFooter =>
      'Сюда пишет ваш сервер, потому что вы — его администратор. Ответить нельзя. На сервере уведомления хранятся 30 дней. Долгое нажатие — скопировать.';

  @override
  String get previewReply => 'Завидую! Возьмёте меня в следующий раз? 😍';

  @override
  String get previewSure => 'Конечно! 🙌';

  @override
  String get wallSameAsAll => 'Как во всех чатах';

  @override
  String get shareContact => 'Поделиться контактом';

  @override
  String get shareContactTo => 'Отправить контакт…';

  @override
  String get contactSent => 'Контакт отправлен';

  @override
  String get contactCardNoName => 'Контакт';

  @override
  String get contactCardNameUnverified => 'Имя из карточки, не проверено';

  @override
  String contactCardPreview(String name) {
    return 'Контакт: $name';
  }
}
