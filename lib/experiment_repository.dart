import 'supabase_config.dart';

class ExperimentRepository {
  static final _client = SupabaseConfig.client;

  /// Save one forward- or reverse-bias reading to PostgreSQL.
  /// Returns the database-generated row ID.
  static Future<String> saveReading({
    required String experimentType,
    required double vin,
    required double vout,
    required double currentMa,
  }) async {
    final row = await _client
        .from('experiment_readings')
        .insert({
          'experiment_type': experimentType,
          'vin': vin,
          'vout': vout,
          'current_ma': currentMa,
        })
        .select('id')
        .single();

    return row['id'].toString();
  }

  /// Fetch saved readings from PostgreSQL.
  static Future<List<Map<String, dynamic>>> fetchReadings() async {
    final rows = await _client
        .from('experiment_readings')
        .select()
        .order('created_at', ascending: true);

    return List<Map<String, dynamic>>.from(rows);
  }

  /// Delete one reading by its database ID.
  static Future<void> deleteReading(String id) async {
    await _client.from('experiment_readings').delete().eq('id', id);
  }

  /// Delete all readings for the selected bias mode.
  static Future<void> clearReadings({required String experimentType}) async {
    await _client
        .from('experiment_readings')
        .delete()
        .eq('experiment_type', experimentType);
  }
}
