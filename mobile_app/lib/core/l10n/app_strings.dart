/// Lightweight localization — no codegen, just a static string map.
///
/// Usage: `S.get('key')` or `S.fmt('n_diseases', [9])` for parameterized strings.
class S {
  S._();

  static String _locale = 'en';

  static String get locale => _locale;

  static void setLocale(String locale) {
    _locale = _strings.containsKey(locale) ? locale : 'en';
  }

  /// Retrieve a localized string by key.
  static String get(String key) =>
      _strings[_locale]?[key] ?? _strings['en']?[key] ?? key;

  /// Retrieve a localized string and replace `{0}`, `{1}`, ... with [args].
  static String fmt(String key, List<Object> args) {
    var result = get(key);
    for (var i = 0; i < args.length; i++) {
      result = result.replaceAll('{$i}', args[i].toString());
    }
    return result;
  }

  // ─────────────────────────── String tables ───────────────────────────

  static const Map<String, Map<String, String>> _strings = {
    'en': _en,
    'vi': _vi,
  };

  static const _en = <String, String>{
    // App
    'app_name': 'AgriKD',
    'app_subtitle': 'Plant Leaf Disease Classification',

    // Navigation
    'nav_home': 'Home',
    'nav_history': 'History',
    'nav_settings': 'Settings',
    'scan': 'Scan',

    // Home — Quick Guide
    'quick_guide': 'Quick Guide',
    'step_select': 'Select leaf type',
    'step_scan': 'Tap Scan',
    'step_result': 'See results',
    'step_history': 'Check history',

    // Home — Leaf type selector
    'select_leaf_type': 'Select type of leaf',
    'search_leaf': 'Search leaf types...',
    'no_match': 'No leaf types found',
    'n_diseases': '{0} diseases',
    'detectable_diseases': 'Detectable diseases:',
    'plus_healthy': '+ healthy leaf detection',

    // Camera
    'take_photo': 'Take a Photo',
    'checking': 'Checking your leaf...',
    'camera_no_web':
        'Camera is not available on web.\nPick an image from your gallery instead.',
    'pick_gallery': 'Pick from Gallery',
    'camera_needed': 'We need camera access to take photos of your leaves',
    'open_settings': 'Open Settings',
    'camera_unavailable': 'Camera not available',
    'capture_failed': 'Could not take photo',
    'error_generic': 'Something went wrong',

    // Result screen
    'result': 'Result',
    'your_result': 'Your Result',
    'no_result': 'No result available',
    'notes': 'Notes',
    'notes_hint': 'Add notes about this scan...',
    'notes_saved': 'Notes saved',
    'no_notes': 'No notes',
    'save': 'Save',
    'cancel': 'Cancel',
    'saved': 'Saved',
    'save_notes': 'Save Notes',
    'scan_again': 'Scan Again',
    'home': 'Home',
    'all_results': 'All possible results',

    // Detail screen
    'disease_name': 'Disease',
    'local_name': 'Local name',
    'how_sure': 'Certainty',
    'leaf_type': 'Crop type',
    'model_ver': 'App version',
    'processing_time': 'Processing time',
    'scan_detail': 'Scan Details',
    'diagnosis_info': 'Results',
    'metadata': 'Info',
    'date': 'Date',
    'backed_up': 'Backed up',
    'backed_up_at': 'Backed up at',
    'yes': 'Yes',
    'no': 'No',

    // History
    'history': 'History',
    'statistics': 'Statistics',
    'sort_by': 'Sort by',
    'newest_first': 'Newest first',
    'oldest_first': 'Oldest first',
    'most_certain': 'Most certain first',
    'all_types': 'All types',
    'all_time': 'All time',
    'no_scans': 'No photos checked yet',
    'scans_appear_here': 'Your scan history will appear here',
    'sure_pct': '{0}% sure',

    // Relative time
    'just_now': 'Just now',
    'minutes_ago': '{0} min ago',
    'hours_ago': '{0}h ago',
    'days_ago': '{0}d ago',

    // Stats
    'stats_title': 'Statistics',
    'no_data': 'No data yet',
    'start_scanning': 'Take some photos to see statistics',
    'overview': 'Overview',
    'total_scans': 'Photos checked',
    'synced_label': 'Backed up',
    'last_7_days': 'Last 7 Days',
    'common_findings': 'Most common findings',

    // Stats card (home)
    'your_stats': 'Your Stats',
    'scans_stat': 'Scans',
    'top_stat': 'Top',

    // Settings
    'settings': 'Settings',
    'account': 'Account',
    'signed_in': 'Signed in',
    'sign_out': 'Sign Out',
    'login_to_backup': 'Login to back up',
    'login_subtitle': 'Sign in to save your scans across devices',
    'general': 'General',
    'default_crop': 'Default crop type',
    'auto_backup': 'Auto back up',
    'auto_backup_sub': 'Save scans online when connected',
    'appearance': 'Appearance',
    'theme': 'Theme',
    'choose_theme': 'Choose Theme',
    'theme_system': 'System',
    'theme_light': 'Light',
    'theme_dark': 'Dark',
    'language': 'Language',
    'choose_language': 'Choose Language',
    'about': 'About',
    'app_version': 'Plant Leaf Disease Classification\nVersion 1.0.0',
    'models': 'Supported plants',

    // Auth
    'login': 'Login',
    'login_heading': 'AgriKD',
    'login_sub': 'Sign in to save your scans',
    'email': 'Email',
    'email_required': 'Please enter your email',
    'email_invalid': 'Please enter a valid email',
    'password': 'Password',
    'password_required': 'Please enter your password',
    'password_short': 'Password must be at least 6 characters',
    'no_account': "Don't have an account? Create one",
    'create_account': 'Create Account',
    'join_heading': 'Join AgriKD',
    'register_sub': 'Create an account to save scans across devices',
    'confirm_password': 'Confirm Password',
    'password_mismatch': 'Passwords do not match',
    'has_account': 'Already have an account? Login',
    'or': 'OR',
    'sign_in_google': 'Sign in with Google',
    'search_history': 'Search scans...',
    'invalid_image_format': 'Invalid file format. Use JPEG or PNG.',
    'check_email_confirm':
        'Account created! Please check your email to confirm.',

    // Sync
    'sync_now': 'Sync now',
    'sync_success': '{0} scans synced',
    'sync_up_to_date': 'All scans already backed up',
    'sync_not_logged_in': 'Please log in to sync',
    'sync_failed': 'Sync failed. Please try again later.',
    'sync_syncing': 'Syncing...',
    'sync_failed_short': 'Sync failed — tap to retry',
    'sync_not_synced_yet': 'Not synced yet',

    // Email confirmation dialog
    'check_email_title': 'Check Your Email',
    'ok': 'OK',

    // Forgot password
    'forgot_password': 'Forgot password?',
    'forgot_password_sub':
        'Enter your email and we\'ll send you a link to reset your password.',
    'send_reset_link': 'Send Reset Link',
    'reset_email_sent_title': 'Email Sent',
    'reset_email_sent': 'Check your inbox for a password reset link.',
    'back_to_login': 'Back to Login',

    // Reset password (after clicking email link)
    'set_new_password': 'Set New Password',
    'set_new_password_sub': 'Enter your new password below.',
    'new_password': 'New password',
    'confirm_new_password': 'Confirm new password',
    'update_password': 'Update Password',
    'password_updated_title': 'Password Updated',
    'password_updated_msg':
        'Your password has been updated successfully. You can now log in with your new password.',

    // Friendly auth errors (mapped from Supabase AuthException)
    'err_invalid_credentials': 'Incorrect email or password. Please try again.',
    'err_email_not_confirmed':
        'Your email is not verified yet. Please check your inbox.',
    'err_user_already_registered':
        'This email is already registered. Try logging in instead.',
    'err_email_rate_limit':
        'Too many attempts with this email. Please wait a few minutes and try again.',
    'err_rate_limit': 'Too many requests. Please wait a moment and try again.',
    'err_network': 'No internet connection. Please check your network.',
    'err_google_signin_failed':
        'Google sign-in was interrupted. Please try again.',
    'err_google_not_available':
        'Google sign-in is not available right now. Please try email login.',
    'err_auth_generic': 'Something went wrong. Please try again.',

    // Friendly diagnosis errors
    'err_model_corrupted':
        'The AI model file appears damaged. Try reinstalling the app.',
    'err_model_not_loaded':
        'The AI model is still loading. Please wait a moment and try again.',
    'err_invalid_image': 'Could not read this image. Please pick another one.',
    'err_image_too_large':
        'This image is too large. Please use a smaller photo.',
    'err_unsupported_format':
        'Unsupported image format. Please use JPEG or PNG.',
    'err_image_not_found': 'The image file was not found. Please try again.',
    'err_diagnosis_failed':
        'Could not analyze the leaf. Please try with a clearer photo.',
    'err_benchmark_failed': 'Benchmark could not complete. Please try again.',

    // Benchmark
    'benchmark': 'Benchmark',
    'benchmark_sub': 'Test model speed on this device',
    'run_benchmark': 'Run Benchmark',
    'running_benchmark': 'Running benchmark...',
    'benchmark_done': 'Benchmark complete',
    'copy_report': 'Copy Report',
    'report_copied': 'Report copied to clipboard',
    'warm_up': 'Warm-up',
    'iterations': '{0} iterations',
    'delegate': 'Delegate',
    'model_size': 'Model size',
    'lat_mean': 'Mean',
    'lat_min': 'Min',
    'lat_max': 'Max',
    'lat_p99': 'P99',
    'fps': 'FPS',

    // Filters
    'min_confidence': 'Minimum confidence',
    'confidence': 'Confidence',
    'clear': 'Clear',
    'apply': 'Apply',

    // Status
    'offline_mode': 'Offline mode — sync features unavailable',

    // Model report
    'report_result': 'Report',
    'report_wrong_result': 'Report wrong result',
    'report_reason_hint': 'Why is this result incorrect?',
    'submit_report': 'Submit report',
    'report_sent': 'Report submitted. Thank you!',
    'report_failed': 'Could not send report. Try again later.',
  };

  static const _vi = <String, String>{
    // App
    'app_name': 'AgriKD',
    'app_subtitle': 'Phân loại bệnh lá cây',

    // Navigation
    'nav_home': 'Trang chủ',
    'nav_history': 'Lịch sử',
    'nav_settings': 'Cài đặt',
    'scan': 'Quét',

    // Home — Quick Guide
    'quick_guide': 'Hướng dẫn',
    'step_select': 'Chọn loại lá',
    'step_scan': 'Bấm Quét',
    'step_result': 'Xem kết quả',
    'step_history': 'Xem lịch sử',

    // Home — Leaf type selector
    'select_leaf_type': 'Chọn loại lá',
    'search_leaf': 'Tìm loại lá...',
    'no_match': 'Không tìm thấy loại lá',
    'n_diseases': '{0} loại bệnh',
    'detectable_diseases': 'Các bệnh phát hiện được:',
    'plus_healthy': '+ nhận diện lá khỏe mạnh',

    // Camera
    'take_photo': 'Chụp ảnh',
    'checking': 'Đang kiểm tra lá...',
    'camera_no_web':
        'Camera không khả dụng trên web.\nHãy chọn ảnh từ thư viện.',
    'pick_gallery': 'Chọn từ thư viện',
    'camera_needed': 'Cần quyền camera để chụp ảnh lá',
    'open_settings': 'Mở cài đặt',
    'camera_unavailable': 'Camera không khả dụng',
    'capture_failed': 'Không thể chụp ảnh',
    'error_generic': 'Đã xảy ra lỗi',

    // Result
    'result': 'Kết quả',
    'your_result': 'Kết quả của bạn',
    'no_result': 'Chưa có kết quả',
    'notes': 'Ghi chú',
    'notes_hint': 'Thêm ghi chú...',
    'notes_saved': 'Đã lưu ghi chú',
    'no_notes': 'Chưa có ghi chú',
    'save': 'Lưu',
    'cancel': 'Hủy',
    'saved': 'Đã lưu',
    'save_notes': 'Lưu ghi chú',
    'scan_again': 'Quét lại',
    'home': 'Trang chủ',
    'all_results': 'Tất cả kết quả',

    // Detail
    'disease_name': 'Bệnh',
    'local_name': 'Tên địa phương',
    'how_sure': 'Độ chắc chắn',
    'leaf_type': 'Loại cây',
    'model_ver': 'Phiên bản',
    'processing_time': 'Thời gian xử lý',
    'scan_detail': 'Chi tiết quét',
    'diagnosis_info': 'Kết quả',
    'metadata': 'Thông tin',
    'date': 'Ngày',
    'backed_up': 'Đã sao lưu',
    'backed_up_at': 'Sao lưu lúc',
    'yes': 'Có',
    'no': 'Không',

    // History
    'history': 'Lịch sử',
    'statistics': 'Thống kê',
    'sort_by': 'Sắp xếp',
    'newest_first': 'Mới nhất',
    'oldest_first': 'Cũ nhất',
    'most_certain': 'Chắc chắn nhất',
    'all_types': 'Tất cả',
    'all_time': 'Mọi lúc',
    'no_scans': 'Chưa có ảnh nào',
    'scans_appear_here': 'Lịch sử quét sẽ hiển thị ở đây',
    'sure_pct': 'Chắc {0}%',

    // Relative time
    'just_now': 'Vừa xong',
    'minutes_ago': '{0} phút trước',
    'hours_ago': '{0} giờ trước',
    'days_ago': '{0} ngày trước',

    // Stats
    'stats_title': 'Thống kê',
    'no_data': 'Chưa có dữ liệu',
    'start_scanning': 'Chụp ảnh để xem thống kê',
    'overview': 'Tổng quan',
    'total_scans': 'Ảnh đã kiểm tra',
    'synced_label': 'Đã sao lưu',
    'last_7_days': '7 ngày qua',
    'common_findings': 'Kết quả phổ biến',

    // Stats card
    'your_stats': 'Thống kê',
    'scans_stat': 'Lượt quét',
    'top_stat': 'Hàng đầu',

    // Settings
    'settings': 'Cài đặt',
    'account': 'Tài khoản',
    'signed_in': 'Đã đăng nhập',
    'sign_out': 'Đăng xuất',
    'login_to_backup': 'Đăng nhập để sao lưu',
    'login_subtitle': 'Đăng nhập để lưu kết quả trên nhiều thiết bị',
    'general': 'Chung',
    'default_crop': 'Loại cây mặc định',
    'auto_backup': 'Tự động sao lưu',
    'auto_backup_sub': 'Lưu kết quả khi có mạng',
    'appearance': 'Giao diện',
    'theme': 'Chủ đề',
    'choose_theme': 'Chọn chủ đề',
    'theme_system': 'Hệ thống',
    'theme_light': 'Sáng',
    'theme_dark': 'Tối',
    'language': 'Ngôn ngữ',
    'choose_language': 'Chọn ngôn ngữ',
    'about': 'Giới thiệu',
    'app_version': 'Phân loại bệnh lá cây\nPhiên bản 1.0.0',
    'models': 'Loại cây hỗ trợ',

    // Auth
    'login': 'Đăng nhập',
    'login_heading': 'AgriKD',
    'login_sub': 'Đăng nhập để lưu kết quả',
    'email': 'Email',
    'email_required': 'Vui lòng nhập email',
    'email_invalid': 'Email không hợp lệ',
    'password': 'Mật khẩu',
    'password_required': 'Vui lòng nhập mật khẩu',
    'password_short': 'Mật khẩu ít nhất 6 ký tự',
    'no_account': 'Chưa có tài khoản? Tạo ngay',
    'create_account': 'Tạo tài khoản',
    'join_heading': 'Tham gia AgriKD',
    'register_sub': 'Tạo tài khoản để lưu kết quả',
    'confirm_password': 'Xác nhận mật khẩu',
    'password_mismatch': 'Mật khẩu không khớp',
    'has_account': 'Đã có tài khoản? Đăng nhập',
    'or': 'HOẶC',
    'sign_in_google': 'Đăng nhập bằng Google',
    'search_history': 'Tìm kiếm...',
    'invalid_image_format': 'Định dạng ảnh không hợp lệ. Dùng JPEG hoặc PNG.',
    'check_email_confirm':
        'Tạo tài khoản thành công! Vui lòng kiểm tra email để xác nhận.',

    // Sync
    'sync_now': 'Đồng bộ ngay',
    'sync_success': 'Đã đồng bộ {0} ảnh',
    'sync_up_to_date': 'Tất cả đã được sao lưu',
    'sync_not_logged_in': 'Vui lòng đăng nhập để đồng bộ',
    'sync_failed': 'Đồng bộ thất bại. Vui lòng thử lại sau.',
    'sync_syncing': 'Đang đồng bộ...',
    'sync_failed_short': 'Đồng bộ thất bại — nhấn để thử lại',
    'sync_not_synced_yet': 'Chưa đồng bộ',

    // Email confirmation dialog
    'check_email_title': 'Kiểm tra email',
    'ok': 'OK',

    // Forgot password
    'forgot_password': 'Quên mật khẩu?',
    'forgot_password_sub':
        'Nhập email và chúng tôi sẽ gửi liên kết đặt lại mật khẩu.',
    'send_reset_link': 'Gửi liên kết đặt lại',
    'reset_email_sent_title': 'Đã gửi email',
    'reset_email_sent': 'Kiểm tra hộp thư để tìm liên kết đặt lại mật khẩu.',
    'back_to_login': 'Quay lại đăng nhập',

    // Reset password (after clicking email link)
    'set_new_password': 'Đặt mật khẩu mới',
    'set_new_password_sub': 'Nhập mật khẩu mới bên dưới.',
    'new_password': 'Mật khẩu mới',
    'confirm_new_password': 'Xác nhận mật khẩu mới',
    'update_password': 'Cập nhật mật khẩu',
    'password_updated_title': 'Đã cập nhật',
    'password_updated_msg':
        'Mật khẩu đã được cập nhật thành công. Bạn có thể đăng nhập bằng mật khẩu mới.',

    // Friendly auth errors
    'err_invalid_credentials':
        'Email hoặc mật khẩu không đúng. Vui lòng thử lại.',
    'err_email_not_confirmed':
        'Email chưa được xác nhận. Vui lòng kiểm tra hộp thư.',
    'err_user_already_registered':
        'Email này đã được đăng ký. Hãy thử đăng nhập.',
    'err_email_rate_limit':
        'Quá nhiều lần thử với email này. Vui lòng đợi vài phút rồi thử lại.',
    'err_rate_limit': 'Quá nhiều yêu cầu. Vui lòng đợi một chút rồi thử lại.',
    'err_network': 'Không có kết nối mạng. Vui lòng kiểm tra internet.',
    'err_google_signin_failed':
        'Đăng nhập Google bị gián đoạn. Vui lòng thử lại.',
    'err_google_not_available':
        'Đăng nhập Google không khả dụng. Hãy thử đăng nhập bằng email.',
    'err_auth_generic': 'Đã xảy ra lỗi. Vui lòng thử lại.',

    // Friendly diagnosis errors
    'err_model_corrupted': 'Tệp mô hình AI bị lỗi. Hãy thử cài lại ứng dụng.',
    'err_model_not_loaded':
        'Mô hình AI đang tải. Vui lòng đợi một chút rồi thử lại.',
    'err_invalid_image': 'Không thể đọc ảnh này. Vui lòng chọn ảnh khác.',
    'err_image_too_large': 'Ảnh quá lớn. Vui lòng dùng ảnh nhỏ hơn.',
    'err_unsupported_format':
        'Định dạng ảnh không được hỗ trợ. Vui lòng dùng JPEG hoặc PNG.',
    'err_image_not_found': 'Không tìm thấy ảnh. Vui lòng thử lại.',
    'err_diagnosis_failed':
        'Không thể phân tích lá. Vui lòng thử với ảnh rõ hơn.',
    'err_benchmark_failed': 'Đo hiệu năng thất bại. Vui lòng thử lại.',

    // Benchmark
    'benchmark': 'Đo hiệu năng',
    'benchmark_sub': 'Kiểm tra tốc độ mô hình trên thiết bị',
    'run_benchmark': 'Chạy đo hiệu năng',
    'running_benchmark': 'Đang đo hiệu năng...',
    'benchmark_done': 'Đo hiệu năng xong',
    'copy_report': 'Sao chép báo cáo',
    'report_copied': 'Đã sao chép báo cáo',
    'warm_up': 'Khởi động',
    'iterations': '{0} lần chạy',
    'delegate': 'Delegate',
    'model_size': 'Kích thước mô hình',
    'lat_mean': 'Trung bình',
    'lat_min': 'Thấp nhất',
    'lat_max': 'Cao nhất',
    'lat_p99': 'P99',
    'fps': 'FPS',

    // Filters
    'min_confidence': 'Độ chắc chắn tối thiểu',
    'confidence': 'Độ chắc chắn',
    'clear': 'Xóa',
    'apply': 'Áp dụng',

    // Status
    'offline_mode': 'Chế độ ngoại tuyến — tính năng đồng bộ không khả dụng',

    // Model report
    'report_result': 'Báo lỗi',
    'report_wrong_result': 'Báo kết quả sai',
    'report_reason_hint': 'Tại sao kết quả này không đúng?',
    'submit_report': 'Gửi báo cáo',
    'report_sent': 'Đã gửi báo cáo. Cảm ơn bạn!',
    'report_failed': 'Không thể gửi báo cáo. Thử lại sau.',
  };
}
