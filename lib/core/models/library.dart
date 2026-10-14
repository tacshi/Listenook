import 'json.dart';

class LibraryGroup {
  const LibraryGroup({required this.id, required this.name});

  final String id;
  final String name;

  LibraryGroup copyWith({String? name}) =>
      LibraryGroup(id: id, name: name ?? this.name);

  Map<String, dynamic> toJson() => {'id': id, 'name': name};

  factory LibraryGroup.fromJson(Map<String, dynamic> json) =>
      LibraryGroup(id: json['id'] as String, name: json['name'] as String);
}

class LibraryTag {
  const LibraryTag({required this.id, required this.name});

  final String id;
  final String name;

  LibraryTag copyWith({String? name}) =>
      LibraryTag(id: id, name: name ?? this.name);

  Map<String, dynamic> toJson() => {'id': id, 'name': name};

  factory LibraryTag.fromJson(Map<String, dynamic> json) =>
      LibraryTag(id: json['id'] as String, name: json['name'] as String);
}

class LibraryCatalog {
  const LibraryCatalog({this.groups = const [], this.tags = const []});

  final List<LibraryGroup> groups;
  final List<LibraryTag> tags;

  LibraryCatalog copyWith({
    List<LibraryGroup>? groups,
    List<LibraryTag>? tags,
  }) => LibraryCatalog(groups: groups ?? this.groups, tags: tags ?? this.tags);

  Map<String, dynamic> toJson() => {
    'version': 1,
    'groups': groups.map((group) => group.toJson()).toList(),
    'tags': tags.map((tag) => tag.toJson()).toList(),
  };

  factory LibraryCatalog.fromJson(Map<String, dynamic>? json) => LibraryCatalog(
    groups: mapJsonList(json?['groups'], LibraryGroup.fromJson),
    tags: mapJsonList(json?['tags'], LibraryTag.fromJson),
  );
}
