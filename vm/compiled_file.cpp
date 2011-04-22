/* A CompiledFile represents a .rbc. This class understands the layout
 * of a .rbc file. It can validate and load the body into a CompiledMethod
 * object.
 *
 * CompiledFile::execute is a root stack frame in Rubinius. It's where
 * primary execution begins, when the VM loads the loader.rbc and executes
 * it. */

#include "compiled_file.hpp"
#include "marshal.hpp"
#include "arguments.hpp"
#include "call_frame.hpp"
#include "objectmemory.hpp"
#include "object_utils.hpp"
#include "builtin/staticscope.hpp"
#include "builtin/compiledmethod.hpp"
#include "builtin/class.hpp"
#include "builtin/lazy_executable.hpp"
#include "builtin/symbol.hpp"
#include "builtin/thread.hpp"

namespace rubinius {
  CompiledFile* CompiledFile::load(std::istream& stream, Symbol* path) {
    std::string magic, sum;
    uint64_t ver;

    stream >> magic;
    stream >> ver;
    stream >> sum;
    stream.get(); // eat the \n

    return new CompiledFile(magic, ver, sum, path, &stream);
  }

  CompiledMethod* CompiledFile::load_method(STATE, std::istream& stream, Symbol* path) {
    UnMarshaller mar(state, path, stream);
    return as<CompiledMethod>(mar.unmarshal());
  }

  Object* CompiledFile::body(STATE) {
    UnMarshaller mar(state, path, *stream);
    LazyExecutable::add_index(state, path, (LookupTable*)mar.unmarshal(), stream->tellg());

    return mar.unmarshal();
  }

  bool CompiledFile::execute(STATE) {
    TypedRoot<CompiledMethod*> cm(state, as<CompiledMethod>(body(state)));

    state->thread_state()->clear();

    Arguments args(state->symbol("script"), G(main), 0, 0);

    cm.get()->scope(state, StaticScope::create(state));
    cm.get()->scope()->module(state, G(object));

    cm->execute(state, NULL, cm.get(), G(object), args);

    return true;
  }
}
