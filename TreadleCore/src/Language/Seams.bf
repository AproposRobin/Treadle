using System;
using System.Collections;
using Treadle.Catalog;
using Treadle.Graph;
using Treadle.Document;

namespace Treadle.Language
{
	// The seams between the editor shell and the language model (FORK-NOTES.md, "Seams").
	//
	// The shell asks these interfaces whenever it needs to know something about the language: what
	// colour a type has, whether two pins may be wired, which nodes the Node menu offers, how a
	// document is read from and written to its file, which checks a Sheet has to pass, and how the
	// workspace is validated, built and run (IToolchain, Toolchain.bf). Every interface has a Null /
	// Empty implementation here, which is what the shell runs with until the language plugs in its
	// own through LanguageContext.

	/// The type system: everything the shell asks about a type name (pin colours, wire checks, the
	/// control an unwired input shows, enum members, default values). `ITypeHierarchy` is the part
	/// the generic type-colour rules (Catalog/TypeRules.bf) consult.
	interface ITypeSystem : ITypeHierarchy
	{
		/// The colour family of a type (the pin, wire and swatch colour; Theme maps it).
		TypeFamily Family(StringView typeName);
		/// Whether a value of `from` may be wired into a pin of `to`; `outWhy` (may be null) says
		/// why not.
		Conversion CanConvert(StringView from, StringView to, String outWhy);
		/// Which inline control an unwired input of this type shows (`pinName`: the pin's stable
		/// name; `current`: its value text).
		PinValueKind ValueKind(StringView typeName, StringView current, StringView pinName);
		/// The members of an enum type, in declaration order (nothing when it is not an enum).
		void EnumMembers(StringView typeName, List<String> outMembers);
		/// The value a new pin of this type starts with ("" = none).
		void DefaultValue(StringView typeName, String outValue);
		/// Bumps whenever the answers may have changed (the editor refreshes caches).
		int32 Generation { get; }
	}

	/// Names only: every type is unknown, every wire of matching pin kind is allowed, the colour
	/// comes from the generic rules in TypeRules.
	class NullTypeSystem : ITypeSystem
	{
		public void KindOf(StringView typeName, String outKind) { }
		public bool IsSubtype(StringView derived, StringView baseType) => false;
		public TypeFamily Family(StringView typeName) => TypeRules.Family(typeName, null);
		public Conversion CanConvert(StringView from, StringView to, String outWhy) => TypeRules.CanConvert(from, to, outWhy, null);
		public PinValueKind ValueKind(StringView typeName, StringView current, StringView pinName) => .Expr;
		public void EnumMembers(StringView typeName, List<String> outMembers) { }
		public void DefaultValue(StringView typeName, String outValue) { }
		public int32 Generation => 0;
	}

	/// Where the Node menu's entries come from: the language fills a list of NodeSpec (one per
	/// node the menu offers, with its category, label, keywords and pins).
	interface INodeCatalogSource
	{
		/// Appends every entry (the list is the caller's; the specs become its).
		void Entries(List<NodeSpec> outSpecs);
		/// Bumps whenever the entries changed (the catalog rebuilds its search index).
		int32 Generation { get; }
	}

	/// No entries: the Node menu offers only what the shell builds in.
	class EmptyNodeCatalogSource : INodeCatalogSource
	{
		public void Entries(List<NodeSpec> outSpecs) { }
		public int32 Generation => 0;
	}

	/// The graph file format (Graph-Format.md): how a type file and its layout sidecar are read
	/// and written. The format is the program source, so the shell never looks inside the text.
	interface IGraphCodec
	{
		/// The extension of a type file, with the dot (what the Project Browser lists).
		StringView Extension { get; }
		/// Fills `doc` (header, members, Sheets with their graphs) from `text`. False with
		/// `outError` (line-numbered) when the text does not read.
		bool Read(StringView text, TypeDocument doc, String outError);
		/// Writes `doc` as the type file's content (canonical form).
		bool Write(TypeDocument doc, String outText, String outError);
		/// Fills the layout of `doc` (positions, boxes, knots, views) from a layout file.
		bool ReadLayout(StringView text, TypeDocument doc, String outError);
		/// Writes the layout of `doc` (empty when there is none).
		bool WriteLayout(TypeDocument doc, String outText, String outError);
	}

	/// No format installed: documents open empty and refuse to save.
	class NullGraphCodec : IGraphCodec
	{
		public const String NoFormat = "No graph file format is installed in this build.";
		public StringView Extension => Treadle.Format.FormatNames.TypeExt;

		public bool Read(StringView text, TypeDocument doc, String outError) { outError?.Set(NoFormat); return false; }
		public bool Write(TypeDocument doc, String outText, String outError) { outError?.Set(NoFormat); return false; }
		public bool ReadLayout(StringView text, TypeDocument doc, String outError) { outError?.Set(NoFormat); return false; }
		public bool WriteLayout(TypeDocument doc, String outText, String outError) { outError?.Set(NoFormat); return false; }
	}

	/// The language's own checks of a Sheet (beyond the generic GraphValidator: required inputs,
	/// receivers, lifetimes...). `Check` adds to `g.Errors` and `g.Warnings`; the shell shows them on
	/// the nodes; a document with errors still saves (Editor-Model.md 9), a build refuses.
	interface ILanguageRules
	{
		void Check(Graph g);
		/// Whether `text` is a valid expression for a Math node (the node's body); false with
		/// `outWhy` when it is not.
		bool CheckExpression(StringView text, String outWhy);
	}

	/// No checks.
	class NoLanguageRules : ILanguageRules
	{
		public void Check(Graph g) { }
		public bool CheckExpression(StringView text, String outWhy) => true;
	}
}
