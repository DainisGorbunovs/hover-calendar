#!/usr/bin/env python3
"""Write the "Menu Calendar Weather" shortcut, ready to sign and import.

The shortcut takes a list of points, one Apple Maps link per line in the form
https://maps.apple.com/?ll=<latitude>,<longitude>, and asks Shortcuts' own Get
Weather Forecast action for each one's hourly forecast. Shortcuts runs that
action under its own WeatherKit entitlement, so Menu Calendar can sample a full
grid without one.

Each line goes through the URL action first. Shortcuts will not turn plain text
into a location, but it turns a Maps link into a placemark at exactly the
link's coordinate, which is what the forecast action needs.

It answers with a header line, "menu-calendar-weather 2", so the app can tell an
outdated shortcut from a broken one, then one line per point and hour:

    <point number>|<ISO 8601 date>|<°C>|<mm in the hour>|<km/h>|<degrees the wind blows from>

Each measurement is converted to that fixed unit and written as a plain number
at full precision, so the answer does not depend on the Mac's region or on
the units Apple's forecast happens to arrive in. Numbers may use a decimal
comma in some regions.

Usage:
    tools/make-weather-shortcut.py [output.shortcut]
then sign it (Shortcuts refuses unsigned files) and open it to import:
    shortcuts sign --mode anyone --input <unsigned> --output <signed>
Delete any older "Menu Calendar Weather" in Shortcuts first: importing does not
replace it, and the app runs the shortcut by that exact name.
"""
import pathlib
import plistlib
import sys
import uuid

HOURS = 14            # AppleWeatherField.frameLimit, plus one the app can back-fill from
HEADER = 'menu-calendar-weather 2'   # must match ShortcutWeather.header
TOKEN = '￼'      # where Shortcuts splices a variable into text


def new_id():
    return str(uuid.uuid4()).upper()


def output_of(action_uuid, name):
    return {'Value': {'Type': 'ActionOutput', 'OutputUUID': action_uuid, 'OutputName': name},
            'WFSerializationType': 'WFTextTokenAttachment'}


def variable(name, *aggrandizements):
    value = {'Type': 'Variable', 'VariableName': name}
    if aggrandizements:
        value['Aggrandizements'] = list(aggrandizements)
    return value


def prop(name):
    return {'Type': 'WFPropertyVariableAggrandizement', 'PropertyName': name}


ISO_DATE = {'Type': 'WFDateFormatVariableAggrandizement',
            'WFDateFormatStyle': 'ISO 8601', 'WFISO8601IncludeTime': True}


def unit(kind, symbol):
    """Convert a measurement to a fixed unit, whatever unit it arrived in.

    Spelled the way WorkflowKit's own WFUnitVariableAggrandizement serialises
    itself: the key is WFMeasurementUnitType, not WFUnitType.
    """
    return {'Type': 'WFUnitVariableAggrandizement',
            'WFMeasurementUnitType': kind, 'WFUnitSymbol': symbol}


# A plain number at full precision, rather than a measurement formatted for
# display (which rounds temperature to whole degrees and rain to whole mm).
NUMBER = {'Type': 'WFCoercionVariableAggrandizement', 'CoercionItemClass': 'WFNumberContentItem'}


def text(*parts):
    """A text parameter mixing literal strings and variable dictionaries."""
    string, attachments = '', {}
    for part in parts:
        if isinstance(part, str):
            string += part
        else:
            attachments[f'{{{len(string.encode("utf-16-le")) // 2}, 1}}'] = part
            string += TOKEN
    return {'Value': {'string': string, 'attachmentsByRange': attachments},
            'WFSerializationType': 'WFTextTokenString'}


def action(identifier, **parameters):
    return {'WFWorkflowActionIdentifier': identifier, 'WFWorkflowActionParameters': parameters}


def build():
    split, link, forecast, hours, line = new_id(), new_id(), new_id(), new_id(), new_id()
    inner_end, point_text, outer_end, everything = new_id(), new_id(), new_id(), new_id()
    outer, inner = new_id(), new_id()
    hour = 'Repeat Item 2'

    actions = [
        action('is.workflow.actions.text.split', UUID=split,
               text=text({'Type': 'ExtensionInput'}), WFTextSeparator='New Lines'),
        action('is.workflow.actions.repeat.each', GroupingIdentifier=outer, WFControlFlowMode=0,
               WFInput=output_of(split, 'Split Text')),
        action('is.workflow.actions.url', UUID=link,
               WFURLActionURL=text(variable('Repeat Item'))),
        action('is.workflow.actions.weather.forecast', UUID=forecast,
               WFWeatherForecastType='Hourly',
               WFWeatherCustomLocation=output_of(link, 'URL')),
        action('is.workflow.actions.getitemfromlist', UUID=hours,
               WFInput=output_of(forecast, 'Weather Conditions'),
               WFItemSpecifier='Items in Range', WFItemRangeStart=1, WFItemRangeEnd=HOURS),
        action('is.workflow.actions.repeat.each', GroupingIdentifier=inner, WFControlFlowMode=0,
               WFInput=output_of(hours, 'Items in Range')),
        action('is.workflow.actions.gettext', UUID=line, WFTextActionText=text(
            variable('Repeat Index'), '|',
            variable(hour, prop('Date'), ISO_DATE), '|',
            variable(hour, prop('Temperature'), unit('Temperature', '°C'), NUMBER), '|',
            variable(hour, prop('Precipitation Amount'), unit('Length', 'mm'), NUMBER), '|',
            variable(hour, prop('Wind Speed'), unit('Speed', 'km/h'), NUMBER), '|',
            variable(hour, prop('Wind Direction'), NUMBER))),
        action('is.workflow.actions.repeat.each', GroupingIdentifier=inner, WFControlFlowMode=2,
               UUID=inner_end),
        action('is.workflow.actions.text.combine', UUID=point_text,
               text=output_of(inner_end, 'Repeat Results'), WFTextSeparator='New Lines'),
        action('is.workflow.actions.repeat.each', GroupingIdentifier=outer, WFControlFlowMode=2,
               UUID=outer_end),
        action('is.workflow.actions.text.combine', UUID=everything,
               text=output_of(outer_end, 'Repeat Results'), WFTextSeparator='New Lines'),
        action('is.workflow.actions.output', WFOutput=text(
            HEADER + '\n',
            {'Type': 'ActionOutput', 'OutputUUID': everything, 'OutputName': 'Combined Text'})),
    ]
    return {
        'WFWorkflowActions': actions,
        'WFWorkflowClientVersion': '2607.0.2',
        'WFWorkflowMinimumClientVersion': 900,
        'WFWorkflowMinimumClientVersionString': '900',
        'WFWorkflowHasShortcutInputVariables': True,
        'WFWorkflowHasOutputFallback': False,
        'WFWorkflowIcon': {'WFWorkflowIconGlyphNumber': 59446,
                           'WFWorkflowIconStartColor': 463140863},
        'WFWorkflowImportQuestions': [],
        'WFWorkflowInputContentItemClasses': ['WFStringContentItem', 'WFGenericFileContentItem'],
        'WFWorkflowOutputContentItemClasses': ['WFStringContentItem'],
        'WFWorkflowTypes': [],
        'WFQuickActionSurfaces': [],
    }


def main():
    out = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else 'Menu Calendar Weather.shortcut')
    out.write_bytes(plistlib.dumps(build(), fmt=plistlib.FMT_BINARY))
    print(out)


if __name__ == '__main__':
    main()
