// Simple DOT/GraphViz mode for CodeMirror
(function(mod) {
  if (typeof exports == "object" && typeof module == "object")
    mod(require("../../lib/codemirror"));
  else if (typeof define == "function" && define.amd)
    define(["../../lib/codemirror"], mod);
  else
    mod(CodeMirror);
})(function(CodeMirror) {
  "use strict";

  CodeMirror.defineMode("dot", function() {
    return {
      token: function(stream, state) {
        // Comments
        if (stream.match(/^#.*/)) {
          return "comment";
        }
        if (stream.match(/^\/\/.*/)) {
          return "comment";
        }
        
        // Strings (double quotes)
        if (stream.match(/^"[^"]*"/)) {
          return "string";
        }
        
        // Keywords
        if (stream.match(/^(graph|digraph|subgraph|node|edge|strict)\b/i)) {
          return "keyword";
        }
        
        // Attributes
        if (stream.match(/^(label|color|style|shape|fillcolor|fontcolor|fontsize|fontname|width|height|rank|rankdir|splines|overlap|concentrate)\b/i)) {
          return "attribute";
        }
        
        // Operators
        if (stream.match(/^(--|->|=)/)) {
          return "operator";
        }
        
        // Brackets
        if (stream.match(/^[{}\[\]]/)) {
          return "bracket";
        }
        
        // Port notation (colon)
        if (stream.match(/^:/)) {
          return "operator";
        }
        
        // Numbers
        if (stream.match(/^-?\d+\.?\d*/)) {
          return "number";
        }
        
        // Identifiers
        if (stream.match(/^[a-zA-Z_][a-zA-Z0-9_-]*/)) {
          return "variable";
        }
        
        // Skip whitespace and other characters
        stream.next();
        return null;
      }
    };
  });

  CodeMirror.defineMIME("text/x-dot", "dot");
  CodeMirror.defineMIME("text/vnd.graphviz", "dot");
});
