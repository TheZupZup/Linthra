import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:linthra/core/services/optical/udisks_drive_reading.dart';
import 'package:linthra/core/services/optical/udisks_object_source.dart';

/// A raw signal from somewhere under `/org/freedesktop/UDisks2`.
DBusSignal _signal({
  required String interface,
  required String name,
  List<DBusValue> values = const <DBusValue>[],
  String path = '/org/freedesktop/UDisks2/block_devices/sr0',
}) {
  return DBusSignal(
    sender: UDisks.busName,
    path: DBusObjectPath(path),
    interface: interface,
    name: name,
    values: values,
  );
}

/// `InterfacesAdded` naming [interfaces], with no properties: the shape
/// UDisks2 uses when an object gains an interface.
DBusObjectManagerInterfacesAddedSignal _interfacesAdded(
  List<String> interfaces,
) {
  return DBusObjectManagerInterfacesAddedSignal(
    _signal(
      interface: 'org.freedesktop.DBus.ObjectManager',
      name: 'InterfacesAdded',
      values: <DBusValue>[
        DBusObjectPath('/org/freedesktop/UDisks2/block_devices/sr0'),
        DBusDict(
          DBusSignature('s'),
          DBusSignature('a{sv}'),
          <DBusValue, DBusValue>{
            for (final String interface in interfaces)
              DBusString(interface): DBusDict.stringVariant(
                const <String, DBusValue>{},
              ),
          },
        ),
      ],
    ),
  );
}

DBusObjectManagerInterfacesRemovedSignal _interfacesRemoved(
  List<String> interfaces,
) {
  return DBusObjectManagerInterfacesRemovedSignal(
    _signal(
      interface: 'org.freedesktop.DBus.ObjectManager',
      name: 'InterfacesRemoved',
      values: <DBusValue>[
        DBusObjectPath('/org/freedesktop/UDisks2/block_devices/sr0'),
        DBusArray.string(interfaces),
      ],
    ),
  );
}

DBusPropertiesChangedSignal _propertiesChanged(String interface) {
  return DBusPropertiesChangedSignal(
    _signal(
      interface: 'org.freedesktop.DBus.Properties',
      name: 'PropertiesChanged',
      values: <DBusValue>[
        DBusString(interface),
        DBusDict.stringVariant(const <String, DBusValue>{}),
        DBusArray.string(const <String>[]),
      ],
    ),
  );
}

void main() {
  group('DBusUDisksObjectSource.isRelevantSignal', () {
    test('a drive property change is worth a re-read', () {
      // The common case: a disc going in or coming out moves Drive properties
      // on a drive object that already exists.
      expect(
        DBusUDisksObjectSource.isRelevantSignal(
          _propertiesChanged(UDisks.driveInterface),
        ),
        isTrue,
      );
    });

    test('a block property change is worth a re-read', () {
      expect(
        DBusUDisksObjectSource.isRelevantSignal(
          _propertiesChanged(UDisks.blockInterface),
        ),
        isTrue,
      );
    });

    test('a partition interface arriving alone is worth a re-read', () {
      // The decoder skips a block that is a partition, so an object gaining
      // Partition changes which node names the drive. Ignoring this signal
      // left that change unnoticed until some unrelated event happened to
      // trigger the next read.
      expect(
        DBusUDisksObjectSource.isRelevantSignal(
          _interfacesAdded(<String>[UDisks.partitionInterface]),
        ),
        isTrue,
      );
    });

    test('a partition interface leaving alone is worth a re-read', () {
      expect(
        DBusUDisksObjectSource.isRelevantSignal(
          _interfacesRemoved(<String>[UDisks.partitionInterface]),
        ),
        isTrue,
      );
    });

    test('every interface the decoder reads is watched', () {
      // The rule this filter has to keep: an interface
      // opticalSnapshotFrom looks at, and the filter ignores, is a stale
      // snapshot waiting to happen.
      for (final String interface in <String>[
        UDisks.driveInterface,
        UDisks.blockInterface,
        UDisks.partitionInterface,
      ]) {
        expect(
          DBusUDisksObjectSource.isRelevantSignal(
            _interfacesAdded(<String>[interface]),
          ),
          isTrue,
          reason: interface,
        );
        expect(
          DBusUDisksObjectSource.isRelevantSignal(
            _interfacesRemoved(<String>[interface]),
          ),
          isTrue,
          reason: interface,
        );
      }
    });

    test('a new drive object is worth a re-read', () {
      expect(
        DBusUDisksObjectSource.isRelevantSignal(
          _interfacesAdded(<String>[
            UDisks.blockInterface,
            UDisks.partitionInterface,
          ]),
        ),
        isTrue,
      );
    });

    test('UDisks2 job churn is not', () {
      // UDisks2 is a busy object manager: every mount, unmount, format and
      // job progress update goes past this filter. One `udevadm trigger` must
      // not make Linthra re-read the whole object tree.
      expect(
        DBusUDisksObjectSource.isRelevantSignal(
          _propertiesChanged('org.freedesktop.UDisks2.Job'),
        ),
        isFalse,
      );
      expect(
        DBusUDisksObjectSource.isRelevantSignal(
          _interfacesAdded(<String>['org.freedesktop.UDisks2.Job']),
        ),
        isFalse,
      );
      expect(
        DBusUDisksObjectSource.isRelevantSignal(
          _interfacesRemoved(<String>[
            'org.freedesktop.UDisks2.Filesystem',
            'org.freedesktop.UDisks2.Swapspace',
          ]),
        ),
        isFalse,
      );
    });

    test('a signal that is none of the three shapes is ignored', () {
      expect(
        DBusUDisksObjectSource.isRelevantSignal(
          _signal(
            interface: 'org.freedesktop.UDisks2.Job',
            name: 'Completed',
            values: <DBusValue>[const DBusBoolean(true), const DBusString('')],
          ),
        ),
        isFalse,
      );
    });
  });
}
