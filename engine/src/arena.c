typedef struct {
    size_t capacity;
    size_t used;
    void *memory;
} Arena;

void arena_init(Arena *arena, void *memory, size_t capacity) {
    arena->memory = memory;
    arena->capacity = capacity;
    arena->used = 0;
}

#define arena_push_type(arena, type) (type *)arena_push_type_(arena, sizeof(type))
#define arena_push_array(arena, count, type) (type *)arena_push_type_(arena, (count) * sizeof(type))
void *arena_push_type_(Arena *arena, size_t size) {
    assert((arena->used + size) <= arena->capacity && "ERROR: not enough memory to push to arena");

    void *result = (uint8_t *)arena->memory + arena->used;
    arena->used += size;
    return result;
}
