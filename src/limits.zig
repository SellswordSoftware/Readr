/// Shared limits for archive parsing, decoding, and page layout.
pub const Limits = struct {
    // Image-heavy books need more archive entries than readable spine items.
    max_archive_entries: usize = 640,
    max_epub_manifest_items: usize = 128,
    max_epub_spine_items: usize = 128,
    max_archive_filename_bytes: usize = 256,
    compressed_input_bytes: usize = 4 * 1024,
    // Shared by all stream reads within one bounded workflow update.
    decoder_input_bytes_per_update: usize = 4 * 1024,
    decoder_steps_per_update: usize = 16 * 1024,
    decoder_table_builds_per_update: usize = 4,
    decoded_output_chunk_bytes: usize = 1024,
    forward_chapter_bytes_per_update: usize = 256,
    reconstruction_bytes_per_update: usize = 2 * 1024,
    // Restoration checks elapsed time between completed pages; byte limits still apply.
    restoration_pages_per_update: u8 = 3,
    restoration_work_ms_per_update: u32 = 3,
    prefetch_bytes_per_update: usize = 1024,
    progress_index_bytes_per_update: usize = 512,
    progress_directory_records_per_update: usize = 8,
    opening_directory_buffer_bytes: usize = 4 * 1024,
    opening_directory_records_per_update: usize = 32,
    opening_work_ms_per_update: u32 = 3,
    opening_hash_chunks_per_update: usize = 4,
    opening_metadata_chunks_per_update: usize = 4,
    chapter_directory_records_per_update: usize = 8,
    metadata_read_chunk_bytes: usize = 1024,
    max_container_document_bytes: usize = 1024,
    // Image-heavy publications can have a large OPF even when the reader
    // retains only XHTML/navigation manifest items.
    max_package_document_bytes: usize = 96 * 1024,
    max_navigation_document_bytes: usize = 64 * 1024,
    max_xml_tag_bytes: usize = 1024,
    max_xml_entity_bytes: usize = 32,
    page_line_count: usize = 11,
    page_line_bytes: usize = 384,
};

pub const reader = Limits{};

test "resource policy preserves required stream and DEFLATE bounds" {
    const std = @import("std");
    try std.testing.expect(reader.max_archive_entries <= 640);
    try std.testing.expect(reader.max_epub_manifest_items <= reader.max_epub_spine_items);
    try std.testing.expect(reader.max_epub_spine_items <= 128);
    try std.testing.expect(reader.max_archive_filename_bytes <= 256);
    try std.testing.expect(reader.compressed_input_bytes >= 1024);
    try std.testing.expect(reader.compressed_input_bytes <= 4 * 1024);
    try std.testing.expectEqual(@as(usize, 256), reader.forward_chapter_bytes_per_update);
    try std.testing.expectEqual(@as(usize, 2 * 1024), reader.reconstruction_bytes_per_update);
    try std.testing.expect(reader.reconstruction_bytes_per_update > reader.forward_chapter_bytes_per_update);
    try std.testing.expectEqual(@as(usize, 512), reader.progress_index_bytes_per_update);
    try std.testing.expect(reader.progress_directory_records_per_update <= reader.max_archive_entries);
    try std.testing.expect(reader.opening_directory_records_per_update <= reader.max_archive_entries);
    try std.testing.expect(reader.opening_metadata_chunks_per_update >= 1);
    try std.testing.expect(reader.chapter_directory_records_per_update <= reader.max_archive_entries);
    try std.testing.expect(reader.max_xml_entity_bytes <= reader.max_xml_tag_bytes);
}
