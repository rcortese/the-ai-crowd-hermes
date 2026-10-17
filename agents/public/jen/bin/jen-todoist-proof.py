"""Exact field/identity checker at runtime's independent provider GET boundary.
No output data or inference by title. Labels are compared as sets (provider API
normalization); text, absent/null/empty values and IDs otherwise stay literal.
"""
import datetime as dt
import json
import re
import sys


def valid(task, command, identity, args):
    if not isinstance(task,dict) or task.get('id')!=identity:
        return False
    if task.get('verified',True) is not True:
        return False
    if command=='add-task': return task.get('content')==args[0]
    if command=='update-task-fields':
        content,description,priority=args
        return ((not content or task.get('content')==content)
                and (not description or task.get('description')==description)
                and (not priority or type(task.get('priority')) is int and task['priority']==int(priority)))
    if command=='update-description': return 'description' in task and task['description']==args[0]
    if command=='update-labels':
        labels=sorted(set(label.strip() for label in args[0].split(',') if label.strip()))
        return isinstance(task.get('labels'),list) and sorted(set(task['labels']))==labels
    if command=='move-task': return task.get('project_id')==args[0]
    if command=='move-task-parent': return task.get('parent_id')==args[0]
    if command=='update-deadline-date':
        dt.date.fromisoformat(args[0])
        return isinstance(task.get('deadline'),dict) and task['deadline'].get('date')==args[0]
    if command=='clear-deadline': return 'deadline' in task and task['deadline'] is None
    if command=='update-due':
        due=task.get('due')
        if not isinstance(due,dict): return False
        if re.fullmatch(r'\d{4}-\d{2}-\d{2}',args[0]):
            dt.date.fromisoformat(args[0])
            return due.get('date')==args[0] and due.get('is_recurring') is False
        return due.get('string')==args[0] and due.get('is_recurring') is True
    return False


if __name__=='__main__':
    try:
        task=json.load(sys.stdin)
        ok=valid(task,sys.argv[1],sys.argv[2],sys.argv[3:])
    except (ValueError,TypeError,KeyError,IndexError):
        ok=False
    raise SystemExit(0 if ok else 5)
