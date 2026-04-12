/// Minimal HarfBuzz C API bindings for font loading, outline extraction, and text shaping.
module font.hb;

// Opaque types
struct hb_blob_t;
struct hb_face_t;
struct hb_font_t;
struct hb_draw_funcs_t;
struct hb_buffer_t;
struct hb_language_impl_t;

alias hb_bool_t = int;
alias hb_codepoint_t = uint;
alias hb_position_t = int;
alias hb_mask_t = uint;
alias hb_tag_t = uint;
alias hb_language_t = const(hb_language_impl_t)*;
alias hb_destroy_func_t = void function(void*);

union hb_var_int_t
{
    uint u32;
    int i32;
    ushort[2] u16;
    short[2] i16;
    ubyte[4] u8;
    byte[4] i8;
}

union hb_var_num_t
{
    float f;
    uint u32;
    int i32;
    ushort[2] u16;
    short[2] i16;
    ubyte[4] u8;
    byte[4] i8;
}

struct hb_draw_state_t
{
    hb_bool_t path_open;
    float path_start_x;
    float path_start_y;
    float current_x;
    float current_y;
    hb_var_num_t reserved1;
    hb_var_num_t reserved2;
    hb_var_num_t reserved3;
    hb_var_num_t reserved4;
    hb_var_num_t reserved5;
    hb_var_num_t reserved6;
    hb_var_num_t reserved7;
}

struct hb_glyph_info_t
{
    hb_codepoint_t codepoint;
    hb_mask_t mask;
    uint cluster;
    hb_var_int_t var1;
    hb_var_int_t var2;
}

struct hb_glyph_position_t
{
    hb_position_t x_advance;
    hb_position_t y_advance;
    hb_position_t x_offset;
    hb_position_t y_offset;
    hb_var_int_t var;
}

enum hb_direction_t : uint
{
    HB_DIRECTION_INVALID = 0,
    HB_DIRECTION_LTR = 4,
    HB_DIRECTION_RTL,
    HB_DIRECTION_TTB,
    HB_DIRECTION_BTT,
}

// hb_script_t -- encoded as hb_tag_t via hbTag
enum hb_script_t : hb_tag_t
{
    HB_SCRIPT_COMMON = hbTag('Z','y','y','y'),
    HB_SCRIPT_LATIN = hbTag('L','a','t','n'),
    HB_SCRIPT_HAN = hbTag('H','a','n','i'),
}

hb_tag_t hbTag(char c1, char c2, char c3, char c4)
{
    return (cast(hb_tag_t)c1 << 24) |
           (cast(hb_tag_t)c2 << 16) |
           (cast(hb_tag_t)c3 << 8)  |
           cast(hb_tag_t)c4;
}

// Draw callback function types
alias hb_draw_move_to_func_t = void function(
    hb_draw_funcs_t*, void*, hb_draw_state_t*,
    float, float, void*);

alias hb_draw_line_to_func_t = void function(
    hb_draw_funcs_t*, void*, hb_draw_state_t*,
    float, float, void*);

alias hb_draw_quadratic_to_func_t = void function(
    hb_draw_funcs_t*, void*, hb_draw_state_t*,
    float, float, float, float, void*);

alias hb_draw_cubic_to_func_t = void function(
    hb_draw_funcs_t*, void*, hb_draw_state_t*,
    float, float, float, float, float, float, void*);

alias hb_draw_close_path_func_t = void function(
    hb_draw_funcs_t*, void*, hb_draw_state_t*,
    void*);

struct hb_feature_t
{
    hb_tag_t tag;
    uint value;
    uint start;
    uint end_;
}

// C function bindings
extern(C) nothrow @nogc
{
    // Blob
    hb_blob_t* hb_blob_create_from_file(const(char)* file_name);
    void hb_blob_destroy(hb_blob_t* blob);

    // Face
    hb_face_t* hb_face_create(hb_blob_t* blob, uint index);
    void hb_face_destroy(hb_face_t* face);
    uint hb_face_get_upem(const(hb_face_t)* face);

    // Font
    hb_font_t* hb_font_create(hb_face_t* face);
    void hb_font_destroy(hb_font_t* font);
    hb_bool_t hb_font_get_nominal_glyph(hb_font_t* font,
                                         hb_codepoint_t unicode,
                                         hb_codepoint_t* glyph);
    hb_position_t hb_font_get_glyph_h_advance(hb_font_t* font,
                                                hb_codepoint_t glyph);
    void hb_font_draw_glyph(hb_font_t* font,
                             hb_codepoint_t glyph,
                             hb_draw_funcs_t* dfuncs,
                             void* draw_data);

    // Draw funcs
    hb_draw_funcs_t* hb_draw_funcs_create();
    void hb_draw_funcs_destroy(hb_draw_funcs_t* dfuncs);
    void hb_draw_funcs_set_move_to_func(hb_draw_funcs_t* dfuncs,
                                         hb_draw_move_to_func_t func,
                                         void* user_data, hb_destroy_func_t destroy);
    void hb_draw_funcs_set_line_to_func(hb_draw_funcs_t* dfuncs,
                                         hb_draw_line_to_func_t func,
                                         void* user_data, hb_destroy_func_t destroy);
    void hb_draw_funcs_set_quadratic_to_func(hb_draw_funcs_t* dfuncs,
                                              hb_draw_quadratic_to_func_t func,
                                              void* user_data, hb_destroy_func_t destroy);
    void hb_draw_funcs_set_cubic_to_func(hb_draw_funcs_t* dfuncs,
                                          hb_draw_cubic_to_func_t func,
                                          void* user_data, hb_destroy_func_t destroy);
    void hb_draw_funcs_set_close_path_func(hb_draw_funcs_t* dfuncs,
                                            hb_draw_close_path_func_t func,
                                            void* user_data, hb_destroy_func_t destroy);

    // Buffer
    hb_buffer_t* hb_buffer_create();
    void hb_buffer_destroy(hb_buffer_t* buffer);
    void hb_buffer_add_utf8(hb_buffer_t* buffer,
                             const(char)* text, int text_length,
                             uint item_offset, int item_length);
    void hb_buffer_set_direction(hb_buffer_t* buffer, hb_direction_t direction);
    void hb_buffer_set_script(hb_buffer_t* buffer, hb_script_t script);
    void hb_buffer_set_language(hb_buffer_t* buffer, hb_language_t language);
    void hb_buffer_guess_segment_properties(hb_buffer_t* buffer);
    hb_glyph_info_t* hb_buffer_get_glyph_infos(hb_buffer_t* buffer, uint* length);
    hb_glyph_position_t* hb_buffer_get_glyph_positions(hb_buffer_t* buffer, uint* length);

    // Shaping
    void hb_shape(hb_font_t* font, hb_buffer_t* buffer,
                   const(hb_feature_t)* features, uint num_features);

    // Language
    hb_language_t hb_language_from_string(const(char)* str, int len);
}
