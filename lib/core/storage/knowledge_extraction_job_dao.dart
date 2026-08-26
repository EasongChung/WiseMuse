import 'package:sqflite/sqflite.dart';

import '../models/knowledge_extraction_job.dart';
import '../models/model_ids.dart';

class KnowledgeExtractionJobDao {
  KnowledgeExtractionJobDao(this.db, {this.profileId = 'default'});

  final Database db;
  final String? profileId;

  static const _jobs = 'knowledge_extraction_jobs';
  static const _pages = 'knowledge_extraction_job_pages';

  Future<KnowledgeExtractionJob> createJob({
    required String bookId,
    required Map<int, int> pageChapters,
  }) async {
    final job = KnowledgeExtractionJob.create(
      bookId: bookId,
      profileId: profileId ?? 'default',
      totalPages: pageChapters.length,
    );
    await db.transaction((txn) async {
      await _deleteBookWithExecutor(txn, bookId);
      await txn.insert(_jobs, job.toMap());
      final now = DateTime.now().microsecondsSinceEpoch;
      for (final entry in pageChapters.entries) {
        await txn.insert(_pages, {
          'job_id': job.id,
          'book_id': bookId,
          'profile_id': profileId ?? 'default',
          'page': entry.key,
          'chapter': entry.value,
          'status': KnowledgePageStatus.pending.name,
          'attempt_count': 0,
          'updated_at': now,
        });
      }
    });
    return job;
  }

  Future<KnowledgeExtractionJob?> getByBook(String bookId) async {
    final where = <String>['book_id = ?'];
    final args = <dynamic>[bookId];
    if (profileId != null) {
      where.add('profile_id = ?');
      args.add(profileId);
    }
    final rows = await db.query(
      _jobs,
      where: where.join(' AND '),
      whereArgs: args,
      limit: 1,
    );
    return rows.isEmpty ? null : KnowledgeExtractionJob.fromMap(rows.first);
  }

  Future<List<KnowledgeExtractionJob>> getUnfinished() async {
    final where = <String>["status NOT IN ('completed', 'cancelled')"];
    final args = <dynamic>[];
    if (profileId != null) {
      where.add('profile_id = ?');
      args.add(profileId);
    }
    final rows = await db.query(
      _jobs,
      where: where.join(' AND '),
      whereArgs: args,
      orderBy: 'updated_at ASC',
    );
    return rows.map(KnowledgeExtractionJob.fromMap).toList();
  }

  /// [v0.1.60] 包含 pending / running（lease 过期）/ failed 三类任务，便于失败页恢复。
  Future<List<KnowledgeExtractionJob>> getRecoverable() async {
    final where = <String>[
      "(status = 'pending' "
          "OR (status = 'running' AND (lease_until IS NULL OR lease_until < ?)) "
          "OR status = 'failed')",
    ];
    final args = <dynamic>[DateTime.now().microsecondsSinceEpoch];
    if (profileId != null) {
      where.add('profile_id = ?');
      args.add(profileId);
    }
    final rows = await db.query(
      _jobs,
      where: where.join(' AND '),
      whereArgs: args,
      orderBy: 'updated_at ASC',
    );
    return rows.map(KnowledgeExtractionJob.fromMap).toList();
  }

  Future<List<KnowledgeExtractionJobPage>> getPages(String jobId) async {
    final where = <String>['job_id = ?'];
    final args = <dynamic>[jobId];
    if (profileId != null) {
      where.add('profile_id = ?');
      args.add(profileId);
    }
    final rows = await db.query(
      _pages,
      where: where.join(' AND '),
      whereArgs: args,
      orderBy: 'page ASC',
    );
    return rows.map(KnowledgeExtractionJobPage.fromMap).toList();
  }

  Future<KnowledgeExtractionJobPage?> getPage(String jobId, int page) async {
    final where = <String>['job_id = ?', 'page = ?'];
    final args = <dynamic>[jobId, page];
    if (profileId != null) {
      where.add('profile_id = ?');
      args.add(profileId);
    }
    final rows = await db.query(
      _pages,
      where: where.join(' AND '),
      whereArgs: args,
      limit: 1,
    );
    return rows.isEmpty ? null : KnowledgeExtractionJobPage.fromMap(rows.first);
  }

  /// [v0.1.60] 接管任务：拒绝已 completed；failed 状态且 lease 过期可被接管，
  /// 调用方接管后调用 [resetFailedPages] 把失败页重置为 pending 再续跑。
  Future<String?> claim(
    String jobId, {
    Duration lease = const Duration(minutes: 2),
  }) async {
    final token = newModelId('knowledge_run');
    final now = DateTime.now().microsecondsSinceEpoch;
    final leaseUntil = now + lease.inMicroseconds;
    final where = <String>['id = ?', 'status != ?'];
    final args = <dynamic>[jobId, KnowledgeJobStatus.completed.name];
    if (profileId != null) {
      where.add('profile_id = ?');
      args.add(profileId);
    }
    where.add('(run_token IS NULL OR lease_until IS NULL OR lease_until < ?)');
    args.add(now);
    final changed = await db.update(
      _jobs,
      {
        'status': KnowledgeJobStatus.running.name,
        'run_token': token,
        'lease_until': leaseUntil,
        'last_error': null,
        'updated_at': now,
      },
      where: where.join(' AND '),
      whereArgs: args,
    );
    return changed == 1 ? token : null;
  }

  Future<bool> renew(
    String jobId,
    String token, {
    Duration lease = const Duration(minutes: 2),
  }) async {
    final now = DateTime.now().microsecondsSinceEpoch;
    final changed = await db.update(
      _jobs,
      {'lease_until': now + lease.inMicroseconds, 'updated_at': now},
      where: 'id = ? AND run_token = ?',
      whereArgs: [jobId, token],
    );
    return changed == 1;
  }

  Future<bool> markPageRunning(
    String jobId,
    String token,
    KnowledgeExtractionJobPage page,
  ) async {
    final now = DateTime.now().microsecondsSinceEpoch;
    return db.transaction((txn) async {
      final jobChanged = await txn.update(
        _jobs,
        {'current_page': page.page, 'updated_at': now},
        where: 'id = ? AND run_token = ? AND status = ?',
        whereArgs: [jobId, token, KnowledgeJobStatus.running.name],
      );
      if (jobChanged != 1) return false;
      final pageChanged = await txn.update(
        _pages,
        {
          'status': KnowledgePageStatus.running.name,
          'attempt_count': page.attemptCount + 1,
          'last_error': null,
          'updated_at': now,
        },
        where: "job_id = ? AND page = ? AND status != 'completed'",
        whereArgs: [jobId, page.page],
      );
      if (pageChanged != 1) throw StateError('知识提取页状态已改变');
      return true;
    });
  }

  /// [v0.1.60] 单页失败：仅改页状态、记录错误、保持 job running，
  /// 不再把整本任务置 failed（否则下一页 markPageRunning 会拒绝）。
  /// 失败页允许后续重试；任务全部页处理完后由调用方根据成功/失败汇总最终状态。
  Future<bool> markPageFailed(
    String jobId,
    String token,
    int page,
    String error,
  ) async {
    final now = DateTime.now().microsecondsSinceEpoch;
    return db.transaction((txn) async {
      final changed = await txn.update(
        _jobs,
        {
          // 保持 status=running；释放 lease（让失败页后可被再次 claim）；
          // 错误写到 last_error 供诊断。
          'status': KnowledgeJobStatus.running.name,
          'last_error': error,
          'lease_until': null,
          'updated_at': now,
        },
        where: 'id = ? AND run_token = ?',
        whereArgs: [jobId, token],
      );
      if (changed != 1) return false;
      await txn.update(
        _pages,
        {
          'status': KnowledgePageStatus.failed.name,
          'last_error': error,
          'updated_at': now,
        },
        where: 'job_id = ? AND page = ?',
        whereArgs: [jobId, page],
      );
      return true;
    });
  }

  /// [v0.1.60] 失败页重置为 pending，供下次恢复时重跑。
  Future<bool> resetFailedPages(String jobId, String token) async {
    final now = DateTime.now().microsecondsSinceEpoch;
    return db.transaction((txn) async {
      final jobChanged = await txn.update(
        _jobs,
        {'last_error': null, 'updated_at': now},
        where: 'id = ? AND run_token = ?',
        whereArgs: [jobId, token],
      );
      if (jobChanged != 1) return false;
      await txn.update(
        _pages,
        {
          'status': KnowledgePageStatus.pending.name,
          'last_error': null,
          'updated_at': now,
        },
        where: "job_id = ? AND status = 'failed'",
        whereArgs: [jobId],
      );
      return true;
    });
  }

  Future<bool> completePage(
    DatabaseExecutor executor, {
    required String jobId,
    required String token,
    required int page,
    required int pointCount,
    required bool isLastPage,
  }) async {
    final now = DateTime.now().microsecondsSinceEpoch;
    final pageChanged = await executor.update(
      _pages,
      {
        'status': KnowledgePageStatus.completed.name,
        'last_error': null,
        'completed_at': now,
        'updated_at': now,
      },
      where: "job_id = ? AND page = ? AND status != 'completed'",
      whereArgs: [jobId, page],
    );
    if (pageChanged != 1) return false;
    final completed =
        Sqflite.firstIntValue(
          await executor.rawQuery(
            "SELECT COUNT(*) FROM $_pages WHERE job_id = ? AND status = 'completed'",
            [jobId],
          ),
        ) ??
        0;
    final changed = await executor.update(
      _jobs,
      {
        'status':
            isLastPage
                ? KnowledgeJobStatus.completed.name
                : KnowledgeJobStatus.running.name,
        'completed_pages': completed,
        'point_count': pointCount,
        'last_error': null,
        'lease_until':
            isLastPage ? null : now + const Duration(minutes: 2).inMicroseconds,
        'updated_at': now,
      },
      where: 'id = ? AND run_token = ?',
      whereArgs: [jobId, token],
    );
    return changed == 1;
  }

  Future<void> clearBook(String bookId) => _deleteBookWithExecutor(db, bookId);

  Future<void> _deleteBookWithExecutor(
    DatabaseExecutor executor,
    String bookId,
  ) async {
    final where = <String>['book_id = ?'];
    final args = <dynamic>[bookId];
    if (profileId != null) {
      where.add('profile_id = ?');
      args.add(profileId);
    }
    final jobs = await executor.query(
      _jobs,
      columns: ['id'],
      where: where.join(' AND '),
      whereArgs: args,
    );
    for (final row in jobs) {
      await executor.delete(
        _pages,
        where: 'job_id = ?',
        whereArgs: [row['id']],
      );
    }
    await executor.delete(_jobs, where: where.join(' AND '), whereArgs: args);
  }
}
