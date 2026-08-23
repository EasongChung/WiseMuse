import 'model_ids.dart';

enum KnowledgeJobStatus {
  pending,
  running,
  failed,
  completed,
  cancelled;

  static KnowledgeJobStatus fromName(String? name) =>
      KnowledgeJobStatus.values.firstWhere(
        (value) => value.name == name,
        orElse: () => KnowledgeJobStatus.pending,
      );
}

enum KnowledgePageStatus {
  pending,
  running,
  failed,
  completed;

  static KnowledgePageStatus fromName(String? name) =>
      KnowledgePageStatus.values.firstWhere(
        (value) => value.name == name,
        orElse: () => KnowledgePageStatus.pending,
      );
}

class KnowledgeExtractionJob {
  KnowledgeExtractionJob({
    required this.id,
    required this.bookId,
    this.profileId = 'default',
    required this.status,
    required this.totalPages,
    required this.completedPages,
    this.currentPage,
    this.pointCount = 0,
    this.lastError,
    this.runToken,
    this.leaseUntil,
    required this.createdAt,
    required this.updatedAt,
  });

  factory KnowledgeExtractionJob.create({
    required String bookId,
    String profileId = 'default',
    required int totalPages,
  }) {
    final now = DateTime.now().microsecondsSinceEpoch;
    return KnowledgeExtractionJob(
      id: newModelId('knowledge_job'),
      bookId: bookId,
      profileId: profileId,
      status: KnowledgeJobStatus.pending,
      totalPages: totalPages,
      completedPages: 0,
      createdAt: now,
      updatedAt: now,
    );
  }

  final String id;
  final String bookId;
  final String profileId;
  final KnowledgeJobStatus status;
  final int totalPages;
  final int completedPages;
  final int? currentPage;
  final int pointCount;
  final String? lastError;
  final String? runToken;
  final int? leaseUntil;
  final int createdAt;
  final int updatedAt;

  Map<String, dynamic> toMap() => {
    'id': id,
    'book_id': bookId,
    'profile_id': profileId,
    'status': status.name,
    'total_pages': totalPages,
    'completed_pages': completedPages,
    'current_page': currentPage,
    'point_count': pointCount,
    'last_error': lastError,
    'run_token': runToken,
    'lease_until': leaseUntil,
    'created_at': createdAt,
    'updated_at': updatedAt,
  };

  factory KnowledgeExtractionJob.fromMap(Map<String, dynamic> map) =>
      KnowledgeExtractionJob(
        id: map['id'] as String,
        bookId: map['book_id'] as String,
        profileId: (map['profile_id'] as String?) ?? 'default',
        status: KnowledgeJobStatus.fromName(map['status'] as String?),
        totalPages: (map['total_pages'] as int?) ?? 0,
        completedPages: (map['completed_pages'] as int?) ?? 0,
        currentPage: map['current_page'] as int?,
        pointCount: (map['point_count'] as int?) ?? 0,
        lastError: map['last_error'] as String?,
        runToken: map['run_token'] as String?,
        leaseUntil: map['lease_until'] as int?,
        createdAt: (map['created_at'] as int?) ?? 0,
        updatedAt: (map['updated_at'] as int?) ?? 0,
      );
}

class KnowledgeExtractionJobPage {
  KnowledgeExtractionJobPage({
    required this.jobId,
    required this.bookId,
    required this.page,
    required this.chapter,
    required this.status,
    this.attemptCount = 0,
    this.lastError,
    this.completedAt,
    required this.updatedAt,
  });

  final String jobId;
  final String bookId;
  final int page;
  final int chapter;
  final KnowledgePageStatus status;
  final int attemptCount;
  final String? lastError;
  final int? completedAt;
  final int updatedAt;

  Map<String, dynamic> toMap() => {
    'job_id': jobId,
    'book_id': bookId,
    'page': page,
    'chapter': chapter,
    'status': status.name,
    'attempt_count': attemptCount,
    'last_error': lastError,
    'completed_at': completedAt,
    'updated_at': updatedAt,
  };

  factory KnowledgeExtractionJobPage.fromMap(Map<String, dynamic> map) =>
      KnowledgeExtractionJobPage(
        jobId: map['job_id'] as String,
        bookId: map['book_id'] as String,
        page: (map['page'] as int?) ?? 0,
        chapter: (map['chapter'] as int?) ?? 0,
        status: KnowledgePageStatus.fromName(map['status'] as String?),
        attemptCount: (map['attempt_count'] as int?) ?? 0,
        lastError: map['last_error'] as String?,
        completedAt: map['completed_at'] as int?,
        updatedAt: (map['updated_at'] as int?) ?? 0,
      );
}
