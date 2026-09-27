set pagination off
set width 0
set confirm off
break 'npu::VhaNotifyImp::WaitForCompletion(int)'
commands
  silent
  printf "WAIT this=%p id=%d\n", $x0, $x1
  continue
end
break 'npu::VhaObserver::HandleResponse(int, std::function<void (void*)>, int)'
commands
  silent
  printf "RESP a1=%d a2=%p a3=%d\n", $x1, $x2, $x3
  if $x2 != 0
    x/6xw $x2
  end
  continue
end
break 'npu::VhaDnnTask::VhaDnnTask(unsigned int, npu::VhaObserver*)'
commands
  silent
  printf "TASK ctor id=%d\n", $x1
  continue
end
continue
